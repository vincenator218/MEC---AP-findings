#!/usr/bin/env python3
"""
ebx_parser.py — Frostbite 3 "EBX" (DataContainer) asset parser.

Target format: the EBX layout used by Frostbite 3-era titles (confirmed here
against Mirror's Edge Catalyst, 2016). This is a reflection-based binary
format: every asset is a table of "keyword" strings (type/field names),
"field descriptors" (one row per struct field: name-hash, type, byte offset),
"complex descriptors" (one row per class/struct: name-hash, which fields it
owns, its total size), and then the actual instance data laid out according
to those descriptors.

Reconstructed from the public reference implementation at
https://github.com/NicknineTheEagle/Frostbite-Scripts (frostbite3/ebx.py)
and cross-checked byte-for-byte against a real Mirror's Edge Catalyst EBX
sample (GameConfigurations/RewardsData, GameConfigurations/RunnerKitDefinitionsMeta,
extracted from the "Unavailable Echo Unlocker" mod's .archive payload).

Two confidence tiers, and it's important to keep them straight:

  SCHEMA (header, keyword table, field descriptors, complex descriptors,
  instance/array repeaters) — high confidence. This is a simple, fully
  sequential struct read with no ambiguity, and it lines up exactly with
  the raw bytes inspected by hand (magic at the expected offset, keyword
  table immediately readable as plain ASCII, counts that match the class/
  field names actually present). This alone gives you the full class and
  field name catalog for an asset — which is most of what you need for a
  "spreadsheet of every trigger" — even before instance values are decoded.

  INSTANCE VALUES (walking the actual data for each instance, resolving
  arrays, nested classes, enums) — best effort. The reference source could
  only be recovered as a lossy summary (not verbatim), so some details are
  reconstructed from general Frostbite conventions rather than confirmed
  bytes: fixed String buffer length, exact Enum name resolution, and the
  precise formula for where the "array section" begins. To avoid silently
  producing wrong values, this parser derives the array section's start
  empirically (by tracking the file position after walking every top-level
  instance, which is self-consistent by construction) rather than trusting
  an unverified header formula, and it clearly labels any field it isn't
  confident about instead of guessing silently.

Usage:
    python3 ebx_parser.py <file.ebx> [--dump-instances]

If your .ebx came out of a Frosty mod's .archive/.fbmod pair, strip the
resource wrapper first — search for the magic bytes (see MAGICS below) and
slice from there; see extract_from_archive() for a worked example.
"""
import struct
import sys
import argparse
from dataclasses import dataclass, field as dc_field
from typing import Any


MAGICS = {
    b"\xCE\xD1\xB2\x0F": (1, False),  # version 1, little-endian
    b"\x0F\xB2\xD1\xCE": (1, True),   # version 1, big-endian
    b"\xCE\xD1\xB4\x0F": (2, False),  # version 2, little-endian
    b"\x0F\xB4\xD1\xCE": (2, True),   # version 2, big-endian
}


class FieldType:
    Void = 0x0
    DbObject = 0x1
    ValueType = 0x2
    Class = 0x3
    Array = 0x4
    FixedArray = 0x5
    String = 0x6
    CString = 0x7
    Enum = 0x8
    FileRef = 0x9
    Boolean = 0xA
    Int8 = 0xB
    UInt8 = 0xC
    Int16 = 0xD
    UInt16 = 0xE
    Int32 = 0xF
    UInt32 = 0x10
    Int64 = 0x11
    UInt64 = 0x12
    Float32 = 0x13
    Float64 = 0x14
    GUID = 0x15
    SHA1 = 0x16
    ResourceRef = 0x17

    NAMES = {
        0x0: "Void", 0x1: "DbObject", 0x2: "ValueType", 0x3: "Class",
        0x4: "Array", 0x5: "FixedArray", 0x6: "String", 0x7: "CString",
        0x8: "Enum", 0x9: "FileRef", 0xA: "Boolean", 0xB: "Int8",
        0xC: "UInt8", 0xD: "Int16", 0xE: "UInt16", 0xF: "Int32",
        0x10: "UInt32", 0x11: "Int64", 0x12: "UInt64", 0x13: "Float32",
        0x14: "Float64", 0x15: "GUID", 0x16: "SHA1", 0x17: "ResourceRef",
    }

    @classmethod
    def name(cls, t):
        # actual type is the low byte; high bits carry flags in some titles
        return cls.NAMES.get(t & 0x1F, f"Unknown(0x{t:x})")


# --- Exotic field type codes ------------------------------------------------
# The low-5-bit masking scheme from the reference source (type & 0x1F) checks
# out for the common, small-valued codes (Void/DbObject/FileRef all matched
# a real ME:C sample exactly). But three raw 16-bit type codes seen in that
# same sample don't fit any FieldType 0x0-0x17 that way — all three collapse
# to the same masked value (0x1D=29, undefined), meaning masking throws away
# real information for them. Rather than guess a formula, these three were
# pinned down empirically from field-to-field byte gaps in real instance data
# (e.g. KitGuid -> KitTypeGuid is exactly 16 bytes apart, twice, and
# ObjectVariationGuid exactly fills the last 16 bytes of its struct — so
# 0xc15d reads as a 16-byte GUID with high confidence; 0x407d and 0xc0fd
# both sit in 4-byte gaps consistent with a 32-bit hash). These are very
# likely GLOBAL constants for this game build (not per-file), so they should
# keep working across other ME:C ebx files — but this table is not
# exhaustive. An asset that hits a raw type code not listed here will show
# up as "Unknown(0x..)" in the schema dump; add it here once you've pinned
# it down the same way (or cross-check against FrostyToolsuite, which
# already has the authoritative table).
EXOTIC_TYPES = {
    0x407D: (4, "Sid"),   # 32-bit hashed string id (e.g. *Sid fields, DisplayName)
    0xC15D: (16, "Guid"),  # 16-byte GUID
    0xC0FD: (4, "Hash"),  # 32-bit hash (e.g. reward Hash field)
    0xC13D: (4, "Float32?"),  # lower confidence: seen on StayInFlowSeconds/
                               # Threshold fields that are exactly 4 bytes;
                               # a duration/threshold value strongly suggests
                               # float, but unlike the other three this one
                               # isn't pinned down by a clean byte-gap check
                               # against a sibling field — verify before relying on it.
}


def hasher(keyword: str) -> int:
    """32-bit FNV-1 variant used to hash keyword strings -> field/complex name refs."""
    h = 5381
    for byte in keyword.encode("utf-8"):
        h = (h * 33) ^ byte
        h &= 0xFFFFFFFF
    return h


@dataclass
class Header:
    # Field ORDER here was re-derived empirically against a real ME:C sample
    # (see comment in _parse) rather than trusted blindly from the lossy
    # source summary — the summary's byte-count ("3I6H3I" = 36 bytes) was
    # right, but its guess at which named field sits in which slot was not.
    absStringOffset: int      # I: start of the CString *value* section
    lenStringToEOF: int       # I: absStringOffset + this == EOF (verified)
    numGUID: int               # I: external (cross-file) GUID reference count
    numInstanceRepeater: int   # H
    numGUIDRepeater: int       # H: leading N instance repeaters carry a GUID
    unknown1: int               # H: unconfirmed
    numComplex: int             # H
    numField: int                # H
    lenName: int                  # H: byte length of the keyword/name table,
                                   #    16-byte padded (verified byte-exact)
    lenString: int             # I: byte length of just the string *value* area
                                #    (subset of lenStringToEOF)
    numArrayRepeater: int      # I: verified against TWO independent real
                                #    samples — arrayRepeaterSectionStart +
                                #    numArrayRepeater*12, 16-byte aligned,
                                #    lands exactly on absStringOffset both times
    unknown2: int               # I: unconfirmed, not needed for parsing below


@dataclass
class FieldDescriptor:
    nameHash: int
    type: int
    ref: int
    offset: int
    secondaryOffset: int
    name: str = "?"


@dataclass
class ComplexDescriptor:
    nameHash: int
    fieldStartIndex: int
    numField: int
    alignment: int
    type: int
    size: int
    secondarySize: int
    name: str = "?"

    def getAlignment(self):
        return self.alignment if self.alignment else 4


@dataclass
class InstanceRepeater:
    complexIndex: int
    repetitions: int


@dataclass
class ArrayRepeater:
    offset: int
    repetitions: int
    complexIndex: int


@dataclass
class Complex:
    desc: ComplexDescriptor
    fields: list = dc_field(default_factory=list)  # list of (FieldDescriptor, value)


@dataclass
class DeferredArray:
    """An Array-typed field whose payload we resolve in a second pass,
    once arraySectionStart is known (see module docstring)."""
    repeaterIndex: int


@dataclass
class DeferredLocalRef:
    """A GUID-typed field whose 4-byte value is a plain index into this
    same file's self.instances list (as opposed to the top-bit-set variant,
    which indexes self.externalGUIDs -- see _resolve_guid_like). Confirmed
    against real data: PamProgressionMission.CompletedFlag/.AvailableFlag
    in PlayerProgressionData.bin decode this way to the exact
    PamProgressionFlag instance representing that flag. Deferred because
    self.instances isn't fully populated until phase A finishes -- a
    mission can reference a flag instance that comes later in the file."""
    index: int


class EbxFile:
    def __init__(self, data: bytes, source_name: str = "<mem>"):
        self.data = data
        self.source_name = source_name
        self.buf = memoryview(data)
        self.pos = 0
        self._parse()

    # ---- low-level cursor helpers -------------------------------------------------
    def seek(self, pos):
        self.pos = pos

    def tell(self):
        return self.pos

    def read(self, n):
        b = bytes(self.buf[self.pos:self.pos + n])
        if len(b) != n:
            raise EOFError(f"wanted {n} bytes at {self.pos}, got {len(b)} "
                            f"(file is {len(self.data)} bytes)")
        self.pos += n
        return b

    def align(self, n):
        while self.pos % n != 0:
            self.pos += 1

    def unpack(self, fmt, data):
        prefix = ">" if self.bigEndian else "<"
        return struct.unpack(prefix + fmt, data)

    # ---- top-level parse ------------------------------------------------------
    def _parse(self):
        magic = self.read(4)
        if magic not in MAGICS:
            raise ValueError(
                f"unrecognized EBX magic {magic.hex()} at offset 0 of {self.source_name} "
                f"— is this really an ebx payload, or does it still have a resource "
                f"wrapper in front of it? (see extract_from_archive())"
            )
        self.version, self.bigEndian = MAGICS[magic]

        h = self.unpack("3I6H3I", self.read(36))
        self.header = Header(*h)

        # file GUID (16 bytes), then align to 16
        self.fileGUID = self.read(16)
        self.align(16)

        self.externalGUIDs = [
            (self.read(16), self.read(16)) for _ in range(self.header.numGUID)
        ]

        # keyword / name table: null-separated ascii, length header.lenName
        nameBlob = self.read(self.header.lenName)
        self.keywords = nameBlob.decode("latin1").split("\x00")
        self.keywordDict = {hasher(k): k for k in self.keywords if k}

        self.fieldDescriptors = []
        for _ in range(self.header.numField):
            nameHash, typ, ref, offset, secOffset = self.unpack("IHHii", self.read(16))
            fd = FieldDescriptor(nameHash, typ, ref, offset, secOffset)
            fd.name = self.keywordDict.get(nameHash, f"#{nameHash:08x}")
            self.fieldDescriptors.append(fd)

        self.complexDescriptors = []
        for _ in range(self.header.numComplex):
            nameHash, fieldStart, numField, alignment, typ, size, secSize = \
                self.unpack("IIBBHHH", self.read(16))
            cd = ComplexDescriptor(nameHash, fieldStart, numField, alignment, typ, size, secSize)
            cd.name = self.keywordDict.get(nameHash, f"#{nameHash:08x}")
            self.complexDescriptors.append(cd)

        self.instanceRepeaters = [
            InstanceRepeater(*self.unpack("2H", self.read(4)))
            for _ in range(self.header.numInstanceRepeater)
        ]
        self.align(16)

        self.arrayRepeaters = [
            ArrayRepeater(*self.unpack("3I", self.read(12)))
            for _ in range(self.header.numArrayRepeater)
        ]

        # Remainder of the "string section" (beyond the keyword/name table)
        # holds literal CString field *values* (display names, ids, icon
        # names, ...), addressed by absStringOffset + a per-field byte
        # offset. We don't need to walk it ourselves; readField(CString)
        # seeks into self.data directly.

        # ---- instances: phase A, walk structure, defer array payloads ----
        self.seek(self.header.absStringOffset + self.header.lenString)
        self.instances = []
        nonGUIDindex = 0
        self._deferred = []  # (DeferredArray, container_list, index) patch list

        for i, rep in enumerate(self.instanceRepeaters):
            for _ in range(rep.repetitions):
                cd = self.complexDescriptors[rep.complexIndex]
                self.align(cd.getAlignment())
                if i < self.header.numGUIDRepeater:
                    instGUID = self.read(16)
                else:
                    instGUID = f"<index {nonGUIDindex}>"
                    nonGUIDindex += 1
                inst = self.read_complex(rep.complexIndex, isInstance=True)
                self.instances.append((instGUID, inst))

        # arraySectionStart, derived empirically: file position right after
        # the last top-level instance is fully consumed. Sound because
        # read_complex() always ends by seeking to exactly
        # (complex start + complex.size), so sequential instance reads
        # leave the cursor at a consistent, format-defined boundary
        # regardless of what's inside each instance.
        self.arraySectionStart = self.pos

        # ---- phase B: resolve deferred arrays now that we know where they live ----
        for placeholder, container, idx in self._deferred:
            try:
                container[idx] = self._resolve_array(placeholder.repeaterIndex)
            except (EOFError, IndexError, ValueError) as exc:
                # Don't let one misparsed array (garbage repetitions count,
                # out-of-range offset, ...) take down parsing of the whole
                # file -- this happens even in schema-only mode since phase B
                # runs unconditionally as part of _parse(), not just during
                # --dump-instances. Leave an inline error marker and move on.
                container[idx] = (f"<array resolution failed for repeater "
                                   f"index {placeholder.repeaterIndex}: {exc}>")

    # ---- complex / field reading -----------------------------------------------
    def read_complex(self, complexIndex, isInstance=False):
        cd = self.complexDescriptors[complexIndex]
        base = self.pos
        # Frostbite obfuscates 4-byte-aligned *instances* (not nested
        # inline classes) by shifting every field offset back 8 bytes.
        obfuscationShift = 8 if (isInstance and cd.getAlignment() == 4) else 0

        fds = [self.fieldDescriptors[i]
               for i in range(cd.fieldStartIndex, cd.fieldStartIndex + cd.numField)]

        cmplx = Complex(desc=cd)
        for j, fd in enumerate(fds):
            # Bytes actually available to this field before the next field
            # (or the end of the complex) starts. Needed for FieldType.GUID:
            # despite the name, a "GUID"-typed *field* (not the separate
            # 0xC15D exotic literal-GUID type) turned out to almost always
            # be a 4-byte external-reference index, not a 16-byte value --
            # see read_field's GUID branch for the full story. Passing the
            # real gap lets that branch tell the two apart instead of
            # blindly reading 16 bytes and smearing into the next field.
            nextOffset = fds[j + 1].offset if j + 1 < len(fds) else cd.size
            avail = nextOffset - fd.offset
            self.seek(base + fd.offset - obfuscationShift)
            value = self.read_field(fd, avail=avail)
            cmplx.fields.append((fd, value))

        self.seek(base + cd.size - obfuscationShift)
        return cmplx

    def _resolve_guid_like(self, avail=None):
        """Read a FieldType.GUID-tagged value. Discovered empirically (see
        Progression_TreeGearContent.bin, PamProgressionFlagInfoEntityData):
        despite the type name, this is essentially never a literal 16-byte
        GUID in practice -- every real sample checked (across GameConfigurations
        AND a UI widget blueprint) declares only 4 bytes of room for it. Those
        4 bytes are a little-endian uint32; if the top bit is set, the
        low 31 bits are an index into self.externalGUIDs, whose second
        element is the actual referenced instance's GUID in another file --
        confirmed byte-for-byte: PamProgressionFlagInfoEntityData.FlagGroup/
        .Flag in a UI widget resolve through this exact mechanism to real
        PamProgressionFlagGroup/PamProgressionFlag instance GUIDs in
        PlayerProgressionData.bin. 0xFFFFFFFF is the "unset/null" sentinel
        seen elsewhere in this format. A 16-byte read is kept as a fallback
        for the case (not yet observed) where a field genuinely has the
        room for a literal embedded GUID.
        """
        width = 4 if (avail is None or avail < 16) else 16
        raw = self.read(width)
        if width == 16:
            return raw.hex()
        v = self.unpack("I", raw)[0]
        if v == 0xFFFFFFFF:
            return "<null ref>"
        if v & 0x80000000:
            idx = v & 0x7FFFFFFF
            if idx < len(self.externalGUIDs):
                fileGuid, instGuid = self.externalGUIDs[idx]
                return (f"<external ref: instance={instGuid.hex()} "
                        f"in file={fileGuid.hex()}>")
            return f"<external ref: out-of-range index {idx}>"
        # No top bit: a plain index into this same file's instance list
        # (see DeferredLocalRef docstring). Can't resolve yet -- self.instances
        # may not include the target index until phase A finishes -- so
        # defer it the same way array payloads are deferred.
        return DeferredLocalRef(v)

    def read_field(self, fd: FieldDescriptor, avail=None):
        t = fd.type & 0x1F
        try:
            if t == FieldType.Void:
                return None
            if t == FieldType.Boolean:
                return self.unpack("B", self.read(1))[0] != 0
            if t == FieldType.Int8:
                return self.unpack("b", self.read(1))[0]
            if t == FieldType.UInt8:
                return self.unpack("B", self.read(1))[0]
            if t == FieldType.Int16:
                return self.unpack("h", self.read(2))[0]
            if t == FieldType.UInt16:
                return self.unpack("H", self.read(2))[0]
            if fd.type == 0x407D:
                # "Sid" is NOT a hash -- confirmed by direct test against real
                # data (see FINDINGS.md): its 4-byte value is a plain int32
                # byte-offset into this same file's own embedded string
                # section, decoded exactly like FieldType.CString below
                # (absStringOffset + offset, -1/0xFFFFFFFF == null). Verified
                # against dozens of real examples across multiple files --
                # e.g. PamAchievements.AchievementCode 0x23 -> "ACH04",
                # PlayerProgressionData PamProgressionFlag.Name values ->
                # real flag names like "SecurityCameras_Dt78Destroyed". No
                # hashing, cracking, or wordlist needed for this field type.
                off = self.unpack("i", self.read(4))[0]
                if off == -1:
                    return None
                return self._read_cstring_at(self.header.absStringOffset + off)
            if fd.type in EXOTIC_TYPES:
                size, label = EXOTIC_TYPES[fd.type]
                raw = self.read(size)
                if size == 16:
                    return f"{label}: {raw.hex()}"
                v = self.unpack("I", raw)[0]
                return f"{label}: 0x{v:08x}"
            if t in (FieldType.Int32, FieldType.Enum):
                v = self.unpack("i", self.read(4))[0]
                if t == FieldType.Enum:
                    return ("enum-raw", v)  # name resolution not confirmed, see docstring
                return v
            if t == FieldType.UInt32:
                return self.unpack("I", self.read(4))[0]
            if t == FieldType.Int64:
                return self.unpack("q", self.read(8))[0]
            if t == FieldType.FileRef and fd.ref < len(self.complexDescriptors) and avail is not None:
                # A FileRef whose declared target (fd.ref) is a small class
                # made ENTIRELY of Void-typed members is this format's way of
                # encoding an enum: each member's `.offset` IS the enum's
                # integer value, and `.name` is the string to show for it
                # (e.g. Realm_Client=0, Realm_Server=1, ...). A FileRef whose
                # target has real (non-Void) fields, and whose byte-gap to
                # the next field matches that target's declared size, is
                # instead a genuinely nested inline complex -- confirmed on
                # PamProgressionMission.MissionDescription: declared FileRef,
                # but the gap to the next field is exactly 40 bytes, matching
                # PamMissionDescription's size, and decoding it that way
                # surfaces real fields including .ActiveNameSid (a readable
                # mission name). Falls through to the old raw-8-byte-hex
                # behavior for anything that fits neither pattern.
                refCd = self.complexDescriptors[fd.ref]
                refFields = [self.fieldDescriptors[i] for i in
                             range(refCd.fieldStartIndex, refCd.fieldStartIndex + refCd.numField)]
                if refFields and all((f.type & 0x1F) == FieldType.Void for f in refFields):
                    width = avail if avail in (1, 2, 4, 8) else 4
                    raw = self.read(width)
                    v = int.from_bytes(raw, "little")
                    match = next((f.name for f in refFields if f.offset == v), None)
                    return f"{refCd.name}.{match}" if match else f"{refCd.name}(unresolved={v})"
                if refCd.size and avail >= refCd.size:
                    return self.read_complex(fd.ref, isInstance=False)
            if t in (FieldType.UInt64, FieldType.FileRef, FieldType.ResourceRef):
                v = self.unpack("Q", self.read(8))[0]
                return f"0x{v:016x}"
            if t == FieldType.Float32:
                return self.unpack("f", self.read(4))[0]
            if t == FieldType.Float64:
                return self.unpack("d", self.read(8))[0]
            if t == FieldType.GUID:
                return self._resolve_guid_like(avail=avail)
            if t == FieldType.SHA1:
                return self.read(20).hex()
            if t == FieldType.CString:
                off = self.unpack("i", self.read(4))[0]
                if off == -1:
                    return None
                return self._read_cstring_at(self.header.absStringOffset + off)
            if t == FieldType.String:
                # ASSUMPTION (unconfirmed byte length): fixed inline buffer,
                # commonly 32 bytes in Frostbite 3 titles. Flag if this looks wrong.
                raw = self.read(32)
                return raw.split(b"\x00", 1)[0].decode("latin1")
            if t == FieldType.Class:
                nested = self.read_complex(fd.ref, isInstance=False)
                return nested
            if t == FieldType.Array:
                repIndex = self.unpack("I", self.read(4))[0]
                # defer: array section location isn't known until every
                # top-level instance has been walked (see _parse()).
                placeholder = DeferredArray(repIndex)
                # patched in-place after phase A; caller list is the
                # cmplx.fields list itself, patched via index below
                return placeholder
            if t == FieldType.FixedArray:
                return f"<FixedArray not decoded, ref={fd.ref}>"
            if t == FieldType.DbObject:
                # In this ME:C build, array-typed fields (RunnerKits,
                # Rewards, RewardConditions, Missions, Stats, ...) are
                # declared DbObject (raw type 0x41; 0x41 & 0x1F == 0x01, so
                # the low-5 mask is consistent) rather than the reference
                # source's dedicated Array type (0x4) — but the payload
                # mechanism is identical to what that source describes for
                # Array: the 4 bytes at the field's offset are a direct
                # index into self.arrayRepeaters. Confirmed against real
                # data: for RunnerKitDefinitionsMeta, fields RunnerKits/
                # RunnerKitTypes/InitialRewards decode to repeater indices
                # 78/79/80, which point at arrayRepeaters with complexIndex
                # 4/8/6 — exactly the wrapper complexes each field's `ref`
                # already said they should resolve through.
                repIndex = self.unpack("I", self.read(4))[0]
                return DeferredArray(repIndex)
            return f"<unhandled type {FieldType.name(t)}>"
        except EOFError as e:
            return f"<read error: {e}>"

    def _read_cstring_at(self, absOffset):
        end = self.data.find(b"\x00", absOffset)
        if end == -1:
            end = len(self.data)
        return self.data[absOffset:end].decode("utf-8", "backslashreplace")

    MAX_ARRAY_REPETITIONS = 50000  # safety cap: a misparsed header on an
    # unfamiliar asset type can turn `repetitions` into a huge garbage
    # number, which would otherwise iterate for a very long time before
    # failing (or succeed and produce a garbage-sized result). Bail loudly
    # instead of hanging.

    def _resolve_array(self, repeaterIndex):
        rep = self.arrayRepeaters[repeaterIndex]
        if rep.repetitions > self.MAX_ARRAY_REPETITIONS:
            raise ValueError(f"repeater {repeaterIndex} claims "
                              f"{rep.repetitions} repetitions (> safety cap "
                              f"{self.MAX_ARRAY_REPETITIONS}) — almost "
                              f"certainly a misparse for this asset's "
                              f"structure, not real data")
        # rep.complexIndex names the small wrapper complex (always size 4,
        # one field called "member") — NOT the element type directly. The
        # wrapper's member field says how each element is actually laid
        # out; elements are packed back-to-back with no per-element padding
        # (confirmed: sequential arrayRepeater.offset deltas for real ME:C
        # data match repetitions*elementSize exactly, with the *next*
        # array's start then rounded up to a 16-byte boundary).
        wrapper = self.complexDescriptors[rep.complexIndex]
        memberFd = self.fieldDescriptors[wrapper.fieldStartIndex] if wrapper.numField else None

        saved = self.pos
        self.seek(self.arraySectionStart + rep.offset)
        out = []
        mt = (memberFd.type & 0x1F) if memberFd else None
        for _ in range(rep.repetitions):
            if memberFd is None:
                out.append(f"<empty wrapper complex, nothing to read>")
            elif mt in (FieldType.Class, FieldType.FileRef) and memberFd.ref < len(self.complexDescriptors):
                # Despite the FileRef type tag, inside an array-wrapper this
                # means "nested inline complex of type memberFd.ref" —
                # confirmed by cross-referencing field names against real
                # data (e.g. RunnerKits -> array(member:FileRef ref=PamRunnerKitMeta)
                # -> 77 real-looking kit entries).
                out.append(self.read_complex(memberFd.ref, isInstance=False))
            elif mt == FieldType.GUID:
                # Same discovery as read_field's GUID branch (see
                # _resolve_guid_like docstring): the wrapper complex's own
                # declared size is the real per-element width here, and in
                # every real sample checked it's 4 (an external-ref index),
                # not 16 -- this used to hard-crash array resolution
                # (e.g. PamAchievements.Achievements: "wanted 16 bytes,
                # got 8, EOF") by reading straight past the end of file.
                out.append(self._resolve_guid_like(avail=wrapper.size))
            elif memberFd.type == 0x407D:
                # Sid array member: same string-table-offset decoding as
                # the scalar case in read_field -- see the comment there.
                off = self.unpack("i", self.read(4))[0]
                out.append(None if off == -1 else self._read_cstring_at(self.header.absStringOffset + off))
            elif memberFd.type in EXOTIC_TYPES:
                size, label = EXOTIC_TYPES[memberFd.type]
                raw = self.read(size)
                v = raw.hex() if size == 16 else f"0x{self.unpack('I', raw)[0]:08x}"
                out.append(f"{label}: {v}")
            else:
                out.append(self.read_field(memberFd))
        self.seek(saved)
        return out

    # ---- after phase A, walk the tree once more to patch deferred arrays in place ----
    def _parse_finish_deferred(self):
        # Not used directly: deferral patching happens via a tree walk below,
        # invoked from _parse(). Kept as a separate method name for clarity
        # when reading the flow top-to-bottom.
        pass

    # ---- pretty printing -----------------------------------------------------
    def dump_schema(self, out=sys.stdout):
        print(f"=== {self.source_name} ===", file=out)
        print(f"version={self.version} bigEndian={self.bigEndian}", file=out)
        print(f"complexes={self.header.numComplex} fields={self.header.numField} "
              f"instances={sum(r.repetitions for r in self.instanceRepeaters)} "
              f"arrays={self.header.numArrayRepeater} guids={self.header.numGUID}", file=out)
        print(file=out)
        for cd in self.complexDescriptors:
            print(f"class {cd.name}  (size={cd.size}, align={cd.alignment})", file=out)
            for i in range(cd.fieldStartIndex, cd.fieldStartIndex + cd.numField):
                fd = self.fieldDescriptors[i]
                if fd.type in EXOTIC_TYPES:
                    typeLabel = EXOTIC_TYPES[fd.type][1]
                else:
                    typeLabel = FieldType.name(fd.type)
                print(f"    .{fd.name:<32} {typeLabel:<12} "
                      f"offset={fd.offset} ref={fd.ref}", file=out)
        print(file=out)

    # Depth cap for _format_value, independent of the worklist-level cap in
    # _patch_deferred_arrays. Seen on PlayerTagsDefinitionSettingsMeta: a
    # misdecoded field produces a genuinely deep (not just wide) nested
    # chain -- deep enough to blow Python's recursion limit while printing,
    # even after the worklist-level cap stopped further *resolution*. This
    # stops *printing* early too, since the two blow up independently.
    MAX_FORMAT_DEPTH = 200

    def _format_value(self, v, indent=0):
        pad = "  " * indent
        if indent > self.MAX_FORMAT_DEPTH:
            return (f"{pad}<truncated: nesting exceeded {self.MAX_FORMAT_DEPTH} "
                     f"levels — almost certainly a misdecoded field producing "
                     f"a runaway chain, not real data (see MAX_FORMAT_DEPTH "
                     f"comment)>")
        if isinstance(v, DeferredArray):
            return f"{pad}<unresolved array placeholder — bug: phase B should have patched this>"
        if isinstance(v, DeferredLocalRef):
            return f"{pad}<unresolved local-ref placeholder — bug: phase B should have patched this>"
        if isinstance(v, list):
            lines = [f"{pad}["]
            for item in v:
                lines.append(self._format_value(item, indent + 1))
            lines.append(f"{pad}]")
            return "\n".join(lines)
        if isinstance(v, Complex):
            lines = [f"{pad}{v.desc.name} {{"]
            for fd, fv in v.fields:
                fv_s = self._format_value(fv, indent + 1)
                if "\n" in fv_s:
                    lines.append(f"{pad}  .{fd.name}:")
                    lines.append(fv_s)
                else:
                    lines.append(f"{pad}  .{fd.name} = {fv_s.strip()}")
            lines.append(f"{pad}}}")
            return "\n".join(lines)
        return f"{pad}{v!r}"

    def dump_instances(self, out=sys.stdout):
        for guid, inst in self.instances:
            g = guid if isinstance(guid, str) else guid.hex()
            print(f"--- instance guid={g} type={inst.desc.name} ---", file=out)
            print(self._format_value(inst), file=out)
            print(file=out)


# Global safety cap for _patch_deferred_arrays, separate from the per-array
# MAX_ARRAY_REPETITIONS cap above. On PlayerTagsDefinitionSettingsMeta (a
# nested array-of-structs-containing-another-array shape not seen in any of
# the samples the wrapper->element dispatch was validated against), a single
# misdecoded field turned into a genuinely unbounded expansion: each
# resolved element's own array field happened to resolve through the *same*
# arrayRepeaters slot as its parent, so every element spawned 3 more
# "child" elements forever, each individually well under
# MAX_ARRAY_REPETITIONS (3 < 50000) and each individually a fast, cheap
# read -- so nothing ever raised, it just never terminated. This caps the
# total number of Complex objects the patcher will ever process, so a
# structure like that degrades into a truncation warning instead of hanging.
MAX_DEFERRED_PATCH_WORKLIST_ITEMS = 20_000


def _resolve_local_ref(ebx: EbxFile, idx: int) -> str:
    """Resolve a DeferredLocalRef's plain index into ebx.instances (see that
    class's docstring) into a readable description. Called only after phase
    A has finished, so the full instance list is available regardless of
    whether the target instance appears earlier or later in the file."""
    if idx < len(ebx.instances):
        guid, inst = ebx.instances[idx]
        g = guid if isinstance(guid, str) else guid.hex()
        return f"<local ref: {inst.desc.name} guid={g}>"
    return f"<local ref: out-of-range index {idx}>"


def _patch_deferred_arrays(ebx: EbxFile):
    """Walk every parsed Complex tree and replace DeferredArray placeholders
    with their resolved list, now that arraySectionStart is known. Resolving
    one array can itself produce new Complex objects with their own
    DeferredArray fields (e.g. RunnerKits[i].Rewards) — those weren't part
    of the phase-A tree, so a plain one-pass recursive walk misses them.
    Uses a worklist instead of recursion so freshly-resolved elements get
    queued for their own pass."""
    worklist = [inst for _, inst in ebx.instances]
    processed = 0
    ebx.patch_truncated = False
    while worklist:
        if processed >= MAX_DEFERRED_PATCH_WORKLIST_ITEMS:
            ebx.patch_truncated = True
            print(f"WARNING: {ebx.source_name}: array-patch worklist exceeded "
                  f"{MAX_DEFERRED_PATCH_WORKLIST_ITEMS} processed complexes — "
                  f"this almost certainly means a field is being misdecoded as "
                  f"an array that expands forever (see comment above), not real "
                  f"data. Stopping early; remaining fields are left as unresolved "
                  f"placeholders.", file=sys.stderr)
            break
        processed += 1
        cmplx = worklist.pop()
        for i, (fd, v) in enumerate(cmplx.fields):
            if isinstance(v, DeferredArray):
                if v.repeaterIndex >= len(ebx.arrayRepeaters):
                    # Known open edge case: not every DbObject field's raw
                    # value turns out to be a valid arrayRepeaters index —
                    # seen so far only on some *empty*-looking array fields
                    # in deeply nested elements. Rather than crash the whole
                    # dump over one field, report it and move on.
                    cmplx.fields[i] = (fd, f"<array field with out-of-range "
                                           f"repeater index {v.repeaterIndex} "
                                           f"— likely an empty/zero array using "
                                           f"a convention not yet nailed down>")
                    continue
                try:
                    resolved = ebx._resolve_array(v.repeaterIndex)
                except (EOFError, IndexError, ValueError) as exc:
                    cmplx.fields[i] = (fd, f"<array resolution failed for "
                                           f"repeater index {v.repeaterIndex}: {exc}>")
                    continue
                for j, item in enumerate(resolved):
                    if isinstance(item, Complex):
                        worklist.append(item)
                    elif isinstance(item, DeferredLocalRef):
                        # An array of local same-file references (e.g. a
                        # GUID-member array whose elements are indexes into
                        # ebx.instances rather than an external-file ref).
                        resolved[j] = _resolve_local_ref(ebx, item.index)
                cmplx.fields[i] = (fd, resolved)
            elif isinstance(v, DeferredLocalRef):
                cmplx.fields[i] = (fd, _resolve_local_ref(ebx, v.index))
            elif isinstance(v, Complex):
                worklist.append(v)
            elif isinstance(v, list):
                for j, item in enumerate(v):
                    if isinstance(item, Complex):
                        worklist.append(item)
                    elif isinstance(item, DeferredLocalRef):
                        v[j] = _resolve_local_ref(ebx, item.index)


def parse_ebx(data: bytes, source_name="<mem>") -> EbxFile:
    ebx = EbxFile(data, source_name)
    _patch_deferred_arrays(ebx)
    return ebx


def extract_from_archive(archive_path):
    """Split a Frosty-mod .archive blob into its individual raw EBX payloads
    by scanning for magic bytes. Frosty prefixes each resource with a small
    (~8 byte, format not yet reverse engineered here) block header before
    the actual EBX magic — we skip past it rather than parse it."""
    with open(archive_path, "rb") as f:
        data = f.read()
    magic_positions = sorted(
        idx for m in MAGICS for idx in _find_all(data, m)
    )
    blobs = []
    for i, start in enumerate(magic_positions):
        end = magic_positions[i + 1] - 8 if i + 1 < len(magic_positions) else len(data)
        blobs.append(data[start:end])
    return blobs


def _find_all(data, sub):
    start = 0
    while True:
        idx = data.find(sub, start)
        if idx == -1:
            return
        yield idx
        start = idx + 1


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("path", help="a raw .ebx file, or a Frosty mod .archive to split+parse")
    ap.add_argument("--dump-instances", action="store_true")
    args = ap.parse_args()

    with open(args.path, "rb") as f:
        raw = f.read()

    if raw[:4] in MAGICS:
        blobs = [raw]
    else:
        blobs = extract_from_archive(args.path)
        print(f"[found {len(blobs)} ebx payload(s) inside {args.path}]\n")

    for i, blob in enumerate(blobs):
        ebx = parse_ebx(blob, source_name=f"{args.path}[{i}]")
        ebx.dump_schema()
        if args.dump_instances:
            ebx.dump_instances()

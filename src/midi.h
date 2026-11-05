// CoreMIDI's own headers cannot be translated: they #import a C++ header, which
// translate-c rejects. These declarations are the subset the app calls, laid out
// to the framework's ABI; the framework provides the symbols at link time.
#if defined(__APPLE__)
#include <stddef.h>
#include <stdint.h>

typedef uint32_t OSStatus;
typedef uint32_t MIDIObjectRef;
typedef MIDIObjectRef MIDIClientRef;
typedef MIDIObjectRef MIDIPortRef;
typedef MIDIObjectRef MIDIEndpointRef;
typedef unsigned long ItemCount;

// The framework writes the list as header then packets with no padding at all:
// the first packet starts at byte 4, its length at byte 12 and its bytes at 14.
typedef struct __attribute__((packed)) {
    uint64_t timeStamp;
    uint16_t length;
    uint8_t data[256];
} MIDIPacket;

typedef struct __attribute__((packed)) {
    uint32_t numPackets;
    MIDIPacket packet[1];
} MIDIPacketList;

_Static_assert(offsetof(MIDIPacketList, packet) == 4, "the first packet follows the count");
_Static_assert(offsetof(MIDIPacket, length) == 8, "the length follows the timestamp");
_Static_assert(offsetof(MIDIPacket, data) == 10, "the bytes follow the length");

typedef void (*MIDIReadProc)(const MIDIPacketList *pktlist, void *readProcRefCon, void *srcConnRefCon);

// CFStringRef is a pointer to a CF structure; only its address is ever passed.
typedef const void *CFStringRef;
#define ALCHIVIZ_UTF8 0x08000100

extern OSStatus MIDIClientCreate(CFStringRef name, void *notifyProc, void *notifyRefCon, MIDIClientRef *outClient);
extern OSStatus MIDIClientDispose(MIDIClientRef client);
extern OSStatus MIDIInputPortCreate(MIDIClientRef client, CFStringRef portName, MIDIReadProc readProc, void *refCon, MIDIPortRef *outPort);
extern OSStatus MIDIPortConnectSource(MIDIPortRef port, MIDIEndpointRef source, void *connRefCon);
extern OSStatus MIDIPortDispose(MIDIPortRef port);
extern ItemCount MIDIGetNumberOfSources(void);
extern MIDIEndpointRef MIDIGetSource(ItemCount index);
extern OSStatus MIDIObjectGetStringProperty(MIDIObjectRef object, CFStringRef property, CFStringRef *str);
extern int CFStringGetCString(CFStringRef str, char *buffer, long capacity, uint32_t encoding);
extern CFStringRef CFStringCreateWithCString(const void *alloc, const char *cStr, uint32_t encoding);
extern void CFRelease(const void *ref);
extern const CFStringRef kMIDIPropertyDisplayName;

static inline uint32_t alchiviz_midi_packet_count(const MIDIPacketList *list) {
    return list->numPackets;
}

static inline const MIDIPacket *alchiviz_midi_packet_first(const MIDIPacketList *list) {
    return &list->packet[0];
}

// On arm64 a packet must start 4-byte aligned, which is what the framework's
// own MIDIPacketNext does.
static inline const MIDIPacket *alchiviz_midi_packet_next(const MIDIPacket *packet) {
    return (const MIDIPacket *)(((uintptr_t)(&packet->data[packet->length]) + 3) & ~(uintptr_t)3);
}

static inline const uint8_t *alchiviz_midi_packet_bytes(const MIDIPacket *packet) {
    return packet->data;
}

static inline uint16_t alchiviz_midi_packet_length(const MIDIPacket *packet) {
    return packet->length;
}
#endif

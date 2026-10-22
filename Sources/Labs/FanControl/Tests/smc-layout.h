// The C layout of the AppleSMC parameter block, as public SMC tools
// declare it. The tests compare FanSMCParamBlock's byte offsets with what
// clang computes for this struct, so a layout mistake cannot hide.
#include <stdint.h>

typedef struct { char major; char minor; char build; char reserved[1]; uint16_t release; } FanTestSMCVersion;
typedef struct { uint16_t version; uint16_t length; uint32_t cpuPLimit; uint32_t gpuPLimit; uint32_t memPLimit; } FanTestSMCPLimit;
typedef struct { uint32_t dataSize; uint32_t dataType; char dataAttributes; } FanTestSMCKeyInfo;
typedef struct {
    uint32_t key;
    FanTestSMCVersion vers;
    FanTestSMCPLimit pLimitData;
    FanTestSMCKeyInfo keyInfo;
    char result;
    char status;
    char data8;
    uint32_t data32;
    unsigned char bytes[32];
} FanTestSMCKeyData;

static inline unsigned long fan_test_offset_keyInfo(void) { return __builtin_offsetof(FanTestSMCKeyData, keyInfo); }
static inline unsigned long fan_test_offset_dataType(void) { return __builtin_offsetof(FanTestSMCKeyData, keyInfo.dataType); }
static inline unsigned long fan_test_offset_attributes(void) { return __builtin_offsetof(FanTestSMCKeyData, keyInfo.dataAttributes); }
static inline unsigned long fan_test_offset_result(void) { return __builtin_offsetof(FanTestSMCKeyData, result); }
static inline unsigned long fan_test_offset_data8(void) { return __builtin_offsetof(FanTestSMCKeyData, data8); }
static inline unsigned long fan_test_offset_data32(void) { return __builtin_offsetof(FanTestSMCKeyData, data32); }
static inline unsigned long fan_test_offset_bytes(void) { return __builtin_offsetof(FanTestSMCKeyData, bytes); }
static inline unsigned long fan_test_size(void) { return sizeof(FanTestSMCKeyData); }

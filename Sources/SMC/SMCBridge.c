//
//  SMCBridge.c
//  Zest
//

#include "SMCBridge.h"
#include <string.h>
#include <IOKit/IOKitLib.h>

// 与 AppleSMC 内核扩展约定的结构体布局（总长 80 字节）。
typedef struct {
    uint8_t  major;
    uint8_t  minor;
    uint8_t  build;
    uint8_t  reserved;
    uint16_t release;
} SMCVersion;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} SMCPLimitData;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t  dataAttributes;
} SMCKeyInfoData;

typedef struct {
    uint32_t       key;
    SMCVersion     vers;
    SMCPLimitData  pLimitData;
    SMCKeyInfoData keyInfo;
    uint8_t        result;
    uint8_t        status;
    uint8_t        data8;
    uint32_t       data32;
    uint8_t        bytes[32];
} SMCParamStruct;

_Static_assert(sizeof(SMCParamStruct) == 80, "SMCParamStruct layout mismatch");

enum {
    kSMCHandleYPCEvent  = 2,
    kSMCReadKey         = 5,
    kSMCGetKeyFromIndex = 8,
    kSMCGetKeyInfo      = 9,
};

static io_connect_t gConnection = 0;

int zsmc_open(void) {
    if (gConnection != 0) return 0;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (service == 0) return kIOReturnNotFound;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &gConnection);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS) {
        gConnection = 0;
        return kr;
    }
    return 0;
}

void zsmc_close(void) {
    if (gConnection != 0) {
        IOServiceClose(gConnection);
        gConnection = 0;
    }
}

bool zsmc_is_open(void) {
    return gConnection != 0;
}

static bool zsmc_call(SMCParamStruct *input, SMCParamStruct *output) {
    if (gConnection == 0) return false;
    size_t outSize = sizeof(SMCParamStruct);
    kern_return_t kr = IOConnectCallStructMethod(gConnection, kSMCHandleYPCEvent,
                                                 input, sizeof(SMCParamStruct),
                                                 output, &outSize);
    return kr == KERN_SUCCESS && output->result == 0;
}

bool zsmc_key_info(uint32_t key, ZSMCKeyInfo *outInfo) {
    SMCParamStruct in, out;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = key;
    in.data8 = kSMCGetKeyInfo;
    if (!zsmc_call(&in, &out)) return false;
    if (outInfo) {
        outInfo->dataSize = out.keyInfo.dataSize;
        outInfo->dataType = out.keyInfo.dataType;
        outInfo->attributes = out.keyInfo.dataAttributes;
    }
    return true;
}

bool zsmc_read(uint32_t key, const ZSMCKeyInfo *info, uint8_t outBytes[32]) {
    if (info == NULL || info->dataSize == 0 || info->dataSize > 32) return false;
    SMCParamStruct in, out;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.key = key;
    in.keyInfo.dataSize = info->dataSize;
    in.data8 = kSMCReadKey;
    if (!zsmc_call(&in, &out)) return false;
    memcpy(outBytes, out.bytes, 32);
    return true;
}

bool zsmc_key_at_index(uint32_t index, uint32_t *outKey) {
    SMCParamStruct in, out;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));
    in.data8 = kSMCGetKeyFromIndex;
    in.data32 = index;
    if (!zsmc_call(&in, &out)) return false;
    if (outKey) *outKey = out.key;
    return true;
}

uint32_t zsmc_key_count(void) {
    const uint32_t key = ('#' << 24) | ('K' << 16) | ('E' << 8) | 'Y';
    ZSMCKeyInfo info;
    if (!zsmc_key_info(key, &info)) return 0;
    uint8_t bytes[32] = {0};
    if (!zsmc_read(key, &info, bytes)) return 0;
    return ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) | ((uint32_t)bytes[2] << 8) | bytes[3];
}

//
//  SMCBridge.h
//  Zest
//
//  只读访问 AppleSMC 用户客户端（温度、风扇）。
//  独立实现，未复用 Lemon Cleaner 中 GPLv2 授权的 LemonDaemon SMC 代码。
//  所有函数仅允许在同一个串行队列上调用。
//

#ifndef SMCBridge_h
#define SMCBridge_h

#include <stdint.h>
#include <stdbool.h>

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;   // FourCC，例如 'flt ' / 'sp78' / 'fpe2'
    uint8_t  attributes;
} ZSMCKeyInfo;

/// 打开 AppleSMC 连接。成功返回 0，否则返回 IOKit 错误码。
int  zsmc_open(void);
void zsmc_close(void);
bool zsmc_is_open(void);

/// 读取全部 key 数量（'#KEY'），失败返回 0。
uint32_t zsmc_key_count(void);
/// 按索引枚举 key。
bool zsmc_key_at_index(uint32_t index, uint32_t *outKey);
/// 查询 key 的类型与长度。
bool zsmc_key_info(uint32_t key, ZSMCKeyInfo *outInfo);
/// 读取原始字节（最多 32 字节）。
bool zsmc_read(uint32_t key, const ZSMCKeyInfo *info, uint8_t outBytes[32]);

#endif

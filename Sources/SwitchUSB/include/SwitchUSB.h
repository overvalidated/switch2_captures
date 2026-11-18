#ifndef SWITCH_USB_H
#define SWITCH_USB_H

#include <stdint.h>

typedef struct SwitchUSBConnection SwitchUSBConnection;

// Returns the registry ID of the first Switch 2 USB transfer interface, or zero.
uint64_t SwitchUSBFind(void);
int32_t SwitchUSBOpen(uint64_t registryID, SwitchUSBConnection **connection);
void SwitchUSBClose(SwitchUSBConnection *connection);
int32_t SwitchUSBWrite(SwitchUSBConnection *connection, uint8_t *bytes, uint32_t count);
int32_t SwitchUSBRead(SwitchUSBConnection *connection, uint8_t *bytes, uint32_t *count);

#endif

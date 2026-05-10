//
//  PowerMateLEDControl.h
//  LED control for Griffin PowerMate (USB vendor control requests).
//

#ifndef PowerMateLEDControl_h
#define PowerMateLEDControl_h

#include <stdint.h>

// Returns 0 on success; -1 device not found; -2 device open failed (e.g. in use); -3 request failed.
int PowerMateLEDSetBrightness(uint32_t vendorID, uint32_t productID, uint64_t locationID, uint8_t brightness);

int PowerMateLEDSetPulseAsleep(uint32_t vendorID, uint32_t productID, uint64_t locationID, int on);
int PowerMateLEDSetPulseAwake(uint32_t vendorID, uint32_t productID, uint64_t locationID, int on);

// pulseTable 0-2; op 0=divide 1=normal 2=multiply; arg 1-255 for op 0/2.
int PowerMateLEDSetPulseMode(uint32_t vendorID, uint32_t productID, uint64_t locationID,
                             uint8_t pulseTable, uint8_t op, uint8_t arg);

#endif /* PowerMateLEDControl_h */

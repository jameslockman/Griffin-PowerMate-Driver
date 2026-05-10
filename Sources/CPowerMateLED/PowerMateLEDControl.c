//
//  PowerMateLEDControl.c
//  Sends USB vendor control requests to the Griffin PowerMate LED (Linux powermate.c protocol).
//

#include "PowerMateLEDControl.h"
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <CoreFoundation/CoreFoundation.h>

#define POWERMATE_VENDOR_REQUEST_TYPE  0x41u
#define POWERMATE_VENDOR_REQUEST       0x01u
#define SET_STATIC_BRIGHTNESS          0x01u
#define SET_PULSE_ASLEEP               0x02u
#define SET_PULSE_AWAKE                0x03u
#define SET_PULSE_MODE                 0x04u

static io_service_t findPowerMateUSBDevice(uint32_t vendorID, uint32_t productID, uint64_t locationID) {
    CFMutableDictionaryRef match = IOServiceMatching(kIOUSBDeviceClassName);
    if (!match) return 0;

    CFNumberRef vidNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &vendorID);
    CFNumberRef pidNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &productID);
    if (!vidNum || !pidNum) { if (vidNum) CFRelease(vidNum); if (pidNum) CFRelease(pidNum); return 0; }
    CFDictionarySetValue(match, CFSTR(kUSBVendorID), vidNum);
    CFDictionarySetValue(match, CFSTR(kUSBProductID), pidNum);
    CFRelease(vidNum);
    CFRelease(pidNum);
    io_iterator_t iter = 0;
    IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter);
    if (!iter) return 0;

    io_service_t device = 0;
    while ((device = IOIteratorNext(iter)) != 0) {
        CFTypeRef locRef = IORegistryEntryCreateCFProperty(device, CFSTR("locationID"), kCFAllocatorDefault, 0);
        if (locRef && CFGetTypeID(locRef) == CFNumberGetTypeID()) {
            uint64_t loc = 0;
            if (CFNumberGetValue((CFNumberRef)locRef, kCFNumberLongLongType, &loc) && loc == locationID) {
                CFRelease(locRef);
                IOObjectRelease(iter);
                return device;
            }
        }
        if (locRef) CFRelease(locRef);
        IOObjectRelease(device);
    }
    IOObjectRelease(iter);
    return 0;
}

static int sendControlRequest(io_service_t usbDevice, uint16_t wValue, uint16_t wIndex) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    HRESULT res = IOCreatePlugInInterfaceForService(usbDevice, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    if (res != kIOReturnSuccess || !plugin) return -1;

    IOUSBDeviceInterface182 **dev = NULL;
    res = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID182), (LPVOID *)&dev);
    (*plugin)->Release(plugin);
    if (res != S_OK || !dev) return -1;

    res = (*dev)->USBDeviceOpen(dev);
    if (res != kIOReturnSuccess) {
        (*dev)->Release(dev);
        return -2;
    }

    IOUSBDevRequest req;
    req.bmRequestType = POWERMATE_VENDOR_REQUEST_TYPE;
    req.bRequest = POWERMATE_VENDOR_REQUEST;
    req.wValue = wValue;
    req.wIndex = wIndex;
    req.wLength = 0;
    req.pData = NULL;
    req.wLenDone = 0;

    res = (*dev)->DeviceRequest(dev, &req);
    (*dev)->USBDeviceClose(dev);
    (*dev)->Release(dev);
    return (res == kIOReturnSuccess) ? 0 : -3;
}

int PowerMateLEDSetBrightness(uint32_t vendorID, uint32_t productID, uint64_t locationID, uint8_t brightness) {
    io_service_t dev = findPowerMateUSBDevice(vendorID, productID, locationID);
    if (!dev) return -1;
    int r = sendControlRequest(dev, SET_STATIC_BRIGHTNESS, (uint16_t)brightness);
    IOObjectRelease(dev);
    return r;
}

int PowerMateLEDSetPulseAsleep(uint32_t vendorID, uint32_t productID, uint64_t locationID, int on) {
    io_service_t dev = findPowerMateUSBDevice(vendorID, productID, locationID);
    if (!dev) return -1;
    int r = sendControlRequest(dev, SET_PULSE_ASLEEP, on ? 1 : 0);
    IOObjectRelease(dev);
    return r;
}

int PowerMateLEDSetPulseAwake(uint32_t vendorID, uint32_t productID, uint64_t locationID, int on) {
    io_service_t dev = findPowerMateUSBDevice(vendorID, productID, locationID);
    if (!dev) return -1;
    int r = sendControlRequest(dev, SET_PULSE_AWAKE, on ? 1 : 0);
    IOObjectRelease(dev);
    return r;
}

int PowerMateLEDSetPulseMode(uint32_t vendorID, uint32_t productID, uint64_t locationID,
                             uint8_t pulseTable, uint8_t op, uint8_t arg) {
    io_service_t dev = findPowerMateUSBDevice(vendorID, productID, locationID);
    if (!dev) return -1;
    uint16_t wValue = (uint16_t)((pulseTable << 8) | SET_PULSE_MODE);
    uint16_t wIndex = (uint16_t)((arg << 8) | op);
    int r = sendControlRequest(dev, wValue, wIndex);
    IOObjectRelease(dev);
    return r;
}

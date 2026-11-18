#include "SwitchUSB.h"

#include <CoreFoundation/CFNumber.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdlib.h>

static const int NintendoVendor = 0x057e;
static const int Switch2AlbumProduct = 0x2061;
static const UInt32 USBTimeoutMilliseconds = 5000;

struct SwitchUSBConnection {
    IOUSBInterfaceInterface500 **interface;
    UInt8 bulkIn;
    UInt8 bulkOut;
};

static bool propertyEquals(io_service_t service, CFStringRef key, int expected) {
    CFTypeRef property = IORegistryEntryCreateCFProperty(service, key, NULL, 0);
    if (!property) {
        return false;
    }
    int value = 0;
    bool matches = CFGetTypeID(property) == CFNumberGetTypeID()
        && CFNumberGetValue(property, kCFNumberIntType, &value) && value == expected;
    CFRelease(property);
    return matches;
}

static bool isAlbumInterface(io_service_t service) {
    if (!IOObjectConformsTo(service, kIOUSBHostInterfaceClassName)
        || !propertyEquals(service, CFSTR(kUSBInterfaceNumber), 0)) {
        return false;
    }
    io_registry_entry_t parent = IO_OBJECT_NULL;
    if (IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) != kIOReturnSuccess) {
        return false;
    }
    bool matches = propertyEquals(parent, CFSTR(kUSBVendorID), NintendoVendor)
        && propertyEquals(parent, CFSTR(kUSBProductID), Switch2AlbumProduct);
    IOObjectRelease(parent);
    return matches;
}

uint64_t SwitchUSBFind(void) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOUSBHostInterfaceClassName),
                                    &iterator) != kIOReturnSuccess) {
        return 0;
    }
    uint64_t registryID = 0;
    io_service_t service;
    while ((service = IOIteratorNext(iterator))) {
        if (isAlbumInterface(service)) {
            IORegistryEntryGetRegistryEntryID(service, &registryID);
        }
        IOObjectRelease(service);
        if (registryID != 0) {
            break;
        }
    }
    IOObjectRelease(iterator);
    return registryID;
}

static IOReturn findBulkPipes(SwitchUSBConnection *connection) {
    IOUSBInterfaceInterface500 **interface = connection->interface;
    UInt8 endpointCount = 0;
    IOReturn status = (*interface)->GetNumEndpoints(interface, &endpointCount);
    if (status != kIOReturnSuccess) {
        return status;
    }
    for (unsigned int pipe = 1; pipe <= endpointCount; pipe++) {
        UInt8 direction, number, type, interval;
        UInt16 packetSize;
        status = (*interface)->GetPipeProperties(interface, pipe, &direction, &number,
                                                &type, &packetSize, &interval);
        if (status != kIOReturnSuccess) {
            return status;
        }
        if (type == kUSBBulk && direction == kUSBIn) {
            connection->bulkIn = pipe;
        }
        if (type == kUSBBulk && direction == kUSBOut) {
            connection->bulkOut = pipe;
        }
    }
    return connection->bulkIn && connection->bulkOut ? kIOReturnSuccess : kIOReturnUnsupported;
}

int32_t SwitchUSBOpen(uint64_t registryID, SwitchUSBConnection **result) {
    *result = NULL;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registryID));
    if (!service) {
        return kIOReturnNoDevice;
    }
    if (!isAlbumInterface(service)) {
        IOObjectRelease(service);
        return kIOReturnNoDevice;
    }

    IOCFPlugInInterface **plugin = NULL;
    SInt32 score;
    IOReturn status = IOCreatePlugInInterfaceForService(service, kIOUSBInterfaceUserClientTypeID,
                                                      kIOCFPlugInInterfaceID, &plugin, &score);
    IOObjectRelease(service);
    if (status != kIOReturnSuccess) {
        return status;
    }

    IOUSBInterfaceInterface500 **interface = NULL;
    HRESULT query = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID500),
                                             (LPVOID *)&interface);
    IODestroyPlugInInterface(plugin);
    if (query != S_OK || !interface) {
        return kIOReturnUnsupported;
    }

    status = (*interface)->USBInterfaceOpen(interface);
    if (status == kIOReturnExclusiveAccess) {
        status = (*interface)->USBInterfaceOpenSeize(interface);
        if (status == kIOReturnNotPermitted || status == kIOReturnNotPrivileged) {
            status = kIOReturnExclusiveAccess;
        }
    }
    if (status != kIOReturnSuccess) {
        (*interface)->Release(interface);
        return status;
    }

    SwitchUSBConnection *connection = calloc(1, sizeof(*connection));
    if (!connection) {
        (*interface)->USBInterfaceClose(interface);
        (*interface)->Release(interface);
        return kIOReturnNoMemory;
    }
    connection->interface = interface;
    status = findBulkPipes(connection);
    if (status != kIOReturnSuccess) {
        SwitchUSBClose(connection);
        return status;
    }
    *result = connection;
    return kIOReturnSuccess;
}

void SwitchUSBClose(SwitchUSBConnection *connection) {
    IOUSBInterfaceInterface500 **interface = connection->interface;
    (*interface)->USBInterfaceClose(interface);
    (*interface)->Release(interface);
    free(connection);
}

int32_t SwitchUSBWrite(SwitchUSBConnection *connection, uint8_t *bytes, uint32_t count) {
    IOUSBInterfaceInterface500 **interface = connection->interface;
    return (*interface)->WritePipeTO(interface, connection->bulkOut, bytes, count,
                                    USBTimeoutMilliseconds, USBTimeoutMilliseconds);
}

int32_t SwitchUSBRead(SwitchUSBConnection *connection, uint8_t *bytes, uint32_t *count) {
    IOUSBInterfaceInterface500 **interface = connection->interface;
    return (*interface)->ReadPipeTO(interface, connection->bulkIn, bytes, count,
                                   USBTimeoutMilliseconds, USBTimeoutMilliseconds);
}

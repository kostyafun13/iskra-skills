#import "ObjCTry.h"
#import <IOBluetooth/IOBluetooth.h>

// Питание Bluetooth — приватные функции IOBluetooth.framework (тот же механизм,
// что у канонной утилиты blueutil; стабильны много лет, работают на Sonoma).
int IOBluetoothPreferenceGetControllerPowerState(void);
void IOBluetoothPreferenceSetControllerPowerState(int state);

BOOL DiktovkaBTPowerOn(void) {
    return IOBluetoothPreferenceGetControllerPowerState() != 0;
}

void DiktovkaBTSetPower(BOOL on) {
    IOBluetoothPreferenceSetControllerPowerState(on ? 1 : 0);
}

NSString * _Nullable DiktovkaBTConnectHeadphones(void) {
    NSArray<IOBluetoothDevice *> *paired = [IOBluetoothDevice pairedDevices];
    IOBluetoothDevice *target = nil;
    for (IOBluetoothDevice *d in paired) {
        if ([(d.name ?: @"") localizedCaseInsensitiveContainsString:@"airpods"]) { target = d; break; }
    }
    if (!target) {   // AirPods не спарены — берём первое аудио-устройство (гарнитуру)
        for (IOBluetoothDevice *d in paired) {
            if (d.deviceClassMajor == kBluetoothDeviceClassMajorAudio) { target = d; break; }
        }
    }
    if (!target) return nil;
    if (target.isConnected) return target.name;
    IOReturn r = [target openConnection];   // блокирует до исхода — звать из фона
    return (r == kIOReturnSuccess || target.isConnected) ? target.name : nil;
}

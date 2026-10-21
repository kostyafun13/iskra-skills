#import <Foundation/Foundation.h>

// Ловушка ObjC-исключений для Swift: AVAudioEngine на рассинхроне аудио-устройств
// (фантомный вход после отвала Bluetooth) кидает NSException, который do/catch
// Swift не видит, а NSApplication молча глотает — получается «тихий срыв».
// Возвращает nil при успехе, иначе текст исключения.
NSString * _Nullable DiktovkaTryBlock(void (NS_NOESCAPE ^ _Nonnull block)(void));

// Тумблер Bluetooth для кнопки Б (Bluetooth.m): питание — приватные функции
// IOBluetooth (механизм blueutil), подключение наушников — IOBluetoothDevice.
BOOL DiktovkaBTPowerOn(void);
void DiktovkaBTSetPower(BOOL on);
// Подключить спаренные AirPods (иначе первую аудио-гарнитуру): имя устройства
// при успехе, nil при провале. Блокирует — звать из фонового потока.
NSString * _Nullable DiktovkaBTConnectHeadphones(void);

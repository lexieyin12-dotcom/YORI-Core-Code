#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

const int leftHand  = 0;
const int rightHand = 1;
const int leftFoot  = 4;
const int rightFoot = 3;

BLECharacteristic *pCharacteristic;
BLEServer *pServer;

bool deviceConnected = false;

#define SERVICE_UUID        "12345678-1234-1234-1234-1234567890ab"
#define CHARACTERISTIC_UUID "abcd1234-5678-1234-5678-abcdef123456"

class MyServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) override {
    deviceConnected = true;
    Serial.println("Phone connected");
  }

  void onDisconnect(BLEServer* pServer) override {
    deviceConnected = false;
    Serial.println("Phone disconnected");

    delay(300);

    BLEDevice::startAdvertising();

    Serial.println("Advertising restarted");
  }
};

void setup() {
  Serial.begin(115200);
  analogReadResolution(12);

  BLEDevice::init("YORI_ESP32");

  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());

  BLEService *pService = pServer->createService(SERVICE_UUID);

  pCharacteristic = pService->createCharacteristic(
    CHARACTERISTIC_UUID,
    BLECharacteristic::PROPERTY_READ |
    BLECharacteristic::PROPERTY_NOTIFY
  );

  pCharacteristic->addDescriptor(new BLE2902());

  pService->start();

  BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(true);

  BLEDevice::startAdvertising();

  Serial.println("BLE ready");
  Serial.println("Device name: YORI_ESP32");
}

void loop() {
  int LH = analogRead(leftHand);
  int RH = analogRead(rightHand);
  int LF = analogRead(leftFoot);
  int RF = analogRead(rightFoot);

  String data =
    "LH:" + String(LH) +
    ",RH:" + String(RH) +
    ",LF:" + String(LF) +
    ",RF:" + String(RF);

  pCharacteristic->setValue(data.c_str());

  if (deviceConnected) {
    pCharacteristic->notify();
  }

  Serial.println(data);

  delay(200);
}
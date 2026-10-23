/*
  ============================================================
  YORI Flex Firmware v1.0
  ============================================================

  Hardware:
  ESP32-S3
  SDA = GPIO4
  SCL = GPIO5

  TCA9548A:
    CH0 -> MPU-6500 @ T3
    CH1 -> MPU-6500 @ T12
    CH2 -> MPU-6500 @ S1
    CH5 -> DFR1184 0-10V ADC

  DFR1184:
    AIN1 -> EMG 1
    AIN2 -> EMG 2
    I2C address = 0x48

  Output:
    USB Serial -> Python
    BLE -> YORI App

  Sampling:
    20 Hz / 50 ms

  Calibration:
    Automatic calibration on startup
    Serial command: CAL
    BLE CONTROL command: CAL
*/

#include <Wire.h>
#include <math.h>

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

#define I2C_COMMUNICATION
#include <DFRobot_ADS1115_0_10V.h>


// ============================================================
// Hardware Configuration
// ============================================================

#define SDA_PIN 4
#define SCL_PIN 5

#define TCA_ADDR 0x70
#define MPU_ADDR 0x68
#define ADC_ADDR 0x48

#define CH_T3   0
#define CH_T12  1
#define CH_S1   2
#define CH_EMG  5


// ============================================================
// MPU-6500 Registers
// ============================================================

#define PWR_MGMT_1    0x6B
#define CONFIG_REG    0x1A
#define GYRO_CONFIG   0x1B
#define ACCEL_CONFIG  0x1C
#define ACCEL_XOUT_H  0x3B

// ±2 g
const float ACCEL_SCALE = 16384.0f;

// ±500 deg/s
const float GYRO_SCALE = 65.5f;


// ============================================================
// BLE
// ============================================================

#define DEVICE_NAME "YORI-Garment"

#define SERVICE_UUID \
  "2F3A0001-7D9A-4C3B-9A21-1234567890AB"

#define DATA_UUID \
  "2F3A0002-7D9A-4C3B-9A21-1234567890AB"

#define GYRO_UUID \
  "2F3A0003-7D9A-4C3B-9A21-1234567890AB"

#define ACCEL_UUID \
  "2F3A0004-7D9A-4C3B-9A21-1234567890AB"

#define CONTROL_UUID \
  "2F3A0005-7D9A-4C3B-9A21-1234567890AB"


BLEServer* pServer = nullptr;

BLECharacteristic* pDataCharacteristic = nullptr;
BLECharacteristic* pGyroCharacteristic = nullptr;
BLECharacteristic* pAccelCharacteristic = nullptr;
BLECharacteristic* pControlCharacteristic = nullptr;

bool deviceConnected = false;

volatile bool calibrationRequested = false;


// ============================================================
// DFR1184
// ============================================================

DFRobot_ADS1115_I2C ads1115(&Wire, ADC_ADDR);

bool adcOK = false;


// ============================================================
// IMU Data
// ============================================================

struct IMUData {
  float ax;
  float ay;
  float az;

  float gx;
  float gy;
  float gz;

  float roll;
  float pitch;
};


struct ZeroData {
  float roll;
  float pitch;
};


ZeroData zeroT3  = {0, 0};
ZeroData zeroT12 = {0, 0};
ZeroData zeroS1  = {0, 0};


// ============================================================
// BLE Packets
// ============================================================

#pragma pack(push, 1)

struct MainPacket {

  uint16_t sequence;

  int16_t t3Roll;
  int16_t t3Pitch;

  int16_t t12Roll;
  int16_t t12Pitch;

  int16_t s1Roll;
  int16_t s1Pitch;

  int16_t emg1;
  int16_t emg2;
};


struct GyroPacket {

  uint16_t sequence;

  int16_t t3x;
  int16_t t3y;
  int16_t t3z;

  int16_t t12x;
  int16_t t12y;
  int16_t t12z;

  int16_t s1x;
  int16_t s1y;
  int16_t s1z;
};


struct AccelPacket {

  uint16_t sequence;

  int16_t t3x;
  int16_t t3y;
  int16_t t3z;

  int16_t t12x;
  int16_t t12y;
  int16_t t12z;

  int16_t s1x;
  int16_t s1y;
  int16_t s1z;
};

#pragma pack(pop)


// ============================================================
// Runtime
// ============================================================

uint16_t sequenceNumber = 0;

unsigned long lastSampleTime = 0;

const unsigned long SAMPLE_INTERVAL_MS = 50;


// ============================================================
// TCA9548A
// ============================================================

void selectChannel(uint8_t channel) {

  if (channel > 7) return;

  Wire.beginTransmission(TCA_ADDR);

  Wire.write(1 << channel);

  Wire.endTransmission();
}


// ============================================================
// MPU Write
// ============================================================

bool writeMPU(uint8_t reg, uint8_t value) {

  Wire.beginTransmission(MPU_ADDR);

  Wire.write(reg);
  Wire.write(value);

  return Wire.endTransmission() == 0;
}


// ============================================================
// MPU Initialization
// ============================================================

bool initMPU(uint8_t channel) {

  selectChannel(channel);

  delay(10);

  // Check presence
  Wire.beginTransmission(MPU_ADDR);

  if (Wire.endTransmission() != 0) {
    return false;
  }

  // Wake MPU
  if (!writeMPU(PWR_MGMT_1, 0x00))
    return false;

  delay(50);

  // DLPF
  writeMPU(CONFIG_REG, 0x03);

  // Gyroscope ±500 deg/s
  writeMPU(GYRO_CONFIG, 0x08);

  // Accelerometer ±2g
  writeMPU(ACCEL_CONFIG, 0x00);

  delay(20);

  return true;
}


// ============================================================
// Read MPU
// ============================================================

bool readIMU(uint8_t channel, IMUData &data) {

  selectChannel(channel);

  Wire.beginTransmission(MPU_ADDR);

  Wire.write(ACCEL_XOUT_H);

  if (Wire.endTransmission(false) != 0) {
    return false;
  }

  uint8_t received = Wire.requestFrom(
    (uint8_t)MPU_ADDR,
    (uint8_t)14
  );

  if (received != 14) {
    return false;
  }


  int16_t rawAx =
    (Wire.read() << 8) | Wire.read();

  int16_t rawAy =
    (Wire.read() << 8) | Wire.read();

  int16_t rawAz =
    (Wire.read() << 8) | Wire.read();


  // Skip temperature
  Wire.read();
  Wire.read();


  int16_t rawGx =
    (Wire.read() << 8) | Wire.read();

  int16_t rawGy =
    (Wire.read() << 8) | Wire.read();

  int16_t rawGz =
    (Wire.read() << 8) | Wire.read();


  // ----------------------------------------------------------
  // Convert raw data
  // ----------------------------------------------------------

  data.ax = rawAx / ACCEL_SCALE;
  data.ay = rawAy / ACCEL_SCALE;
  data.az = rawAz / ACCEL_SCALE;

  data.gx = rawGx / GYRO_SCALE;
  data.gy = rawGy / GYRO_SCALE;
  data.gz = rawGz / GYRO_SCALE;


  // ----------------------------------------------------------
  // Roll / Pitch
  // ----------------------------------------------------------

  data.roll =
    atan2(
      data.ay,
      data.az
    ) * 180.0f / PI;


  data.pitch =
    atan2(
      -data.ax,
      sqrt(
        data.ay * data.ay +
        data.az * data.az
      )
    ) * 180.0f / PI;


  return true;
}


// ============================================================
// Angle Helpers
// ============================================================

float wrap180(float angle) {

  while (angle > 180.0f)
    angle -= 360.0f;

  while (angle <= -180.0f)
    angle += 360.0f;

  return angle;
}


float angleDiff(float current, float zero) {

  return wrap180(current - zero);
}


// ============================================================
// Circular Mean Calibration
// ============================================================

bool calibrateIMU(
  uint8_t channel,
  ZeroData &zero
) {

  const int CALIBRATION_SAMPLES = 60;

  float rollSin = 0;
  float rollCos = 0;

  float pitchSin = 0;
  float pitchCos = 0;

  int validSamples = 0;


  for (int i = 0; i < CALIBRATION_SAMPLES; i++) {

    IMUData data;

    if (readIMU(channel, data)) {

      float rollRad =
        data.roll * PI / 180.0f;

      float pitchRad =
        data.pitch * PI / 180.0f;


      rollSin += sin(rollRad);
      rollCos += cos(rollRad);

      pitchSin += sin(pitchRad);
      pitchCos += cos(pitchRad);

      validSamples++;
    }

    delay(10);
  }


  if (validSamples == 0) {
    return false;
  }


  zero.roll =
    atan2(
      rollSin / validSamples,
      rollCos / validSamples
    ) * 180.0f / PI;


  zero.pitch =
    atan2(
      pitchSin / validSamples,
      pitchCos / validSamples
    ) * 180.0f / PI;


  return true;
}


// ============================================================
// Calibration All Sensors
// ============================================================

void calibrateAll() {

  Serial.println("# CALIBRATION_START");
  Serial.println("# KEEP_STILL");

  delay(2000);


  bool t3OK =
    calibrateIMU(CH_T3, zeroT3);

  bool t12OK =
    calibrateIMU(CH_T12, zeroT12);

  bool s1OK =
    calibrateIMU(CH_S1, zeroS1);


  Serial.print("# T3_ZERO,");
  Serial.print(zeroT3.roll, 3);
  Serial.print(",");
  Serial.println(zeroT3.pitch, 3);


  Serial.print("# T12_ZERO,");
  Serial.print(zeroT12.roll, 3);
  Serial.print(",");
  Serial.println(zeroT12.pitch, 3);


  Serial.print("# S1_ZERO,");
  Serial.print(zeroS1.roll, 3);
  Serial.print(",");
  Serial.println(zeroS1.pitch, 3);


  if (t3OK && t12OK && s1OK) {

    Serial.println("# CALIBRATION_COMPLETE");

  } else {

    Serial.println("# CALIBRATION_WARNING");
  }
}


// ============================================================
// EMG
// ============================================================

float readEMG(uint8_t channel) {

  if (!adcOK) {
    return 0.0f;
  }


  selectChannel(CH_EMG);

  double mv =
    ads1115.getValue(channel);


  if (mv < 0)
    mv = 0;

  if (mv > 10000)
    mv = 10000;


  return (float)mv;
}


// ============================================================
// Safe int16 Scaling
// ============================================================

int16_t scaleValue(
  float value,
  float scale
) {

  float scaled =
    value * scale;


  if (scaled > 32767.0f)
    scaled = 32767.0f;

  if (scaled < -32768.0f)
    scaled = -32768.0f;


  return (int16_t)roundf(scaled);
}


// ============================================================
// BLE Server Callbacks
// ============================================================

class ServerCallbacks :
  public BLEServerCallbacks {

  void onConnect(
    BLEServer* pServer
  ) override {

    deviceConnected = true;

    Serial.println("# BLE_CONNECTED");
  }


  void onDisconnect(
    BLEServer* pServer
  ) override {

    deviceConnected = false;

    Serial.println("# BLE_DISCONNECTED");

    delay(100);

    BLEDevice::startAdvertising();
  }
};


// ============================================================
// BLE Control
// ============================================================

class ControlCallbacks :
  public BLECharacteristicCallbacks {

  void onWrite(
    BLECharacteristic* pCharacteristic
  ) override {

    auto raw =
      pCharacteristic->getValue();

    String command(
      raw.c_str()
    );

    command.trim();
    command.toUpperCase();


    if (command.startsWith("CAL")) {

      calibrationRequested = true;
    }
  }
};


// ============================================================
// BLE Initialization
// ============================================================

void initBLE() {

  BLEDevice::init(
    DEVICE_NAME
  );


  pServer =
    BLEDevice::createServer();


  pServer->setCallbacks(
    new ServerCallbacks()
  );


  BLEService* pService =
    pServer->createService(
      SERVICE_UUID
    );


  // ----------------------------------------------------------
  // Main packet
  // ----------------------------------------------------------

  pDataCharacteristic =
    pService->createCharacteristic(
      DATA_UUID,
      BLECharacteristic::PROPERTY_NOTIFY
    );

  pDataCharacteristic->addDescriptor(
    new BLE2902()
  );


  // ----------------------------------------------------------
  // Gyroscope
  // ----------------------------------------------------------

  pGyroCharacteristic =
    pService->createCharacteristic(
      GYRO_UUID,
      BLECharacteristic::PROPERTY_NOTIFY
    );

  pGyroCharacteristic->addDescriptor(
    new BLE2902()
  );


  // ----------------------------------------------------------
  // Accelerometer
  // ----------------------------------------------------------

  pAccelCharacteristic =
    pService->createCharacteristic(
      ACCEL_UUID,
      BLECharacteristic::PROPERTY_NOTIFY
    );

  pAccelCharacteristic->addDescriptor(
    new BLE2902()
  );


  // ----------------------------------------------------------
  // Control
  // ----------------------------------------------------------

  pControlCharacteristic =
    pService->createCharacteristic(
      CONTROL_UUID,
      BLECharacteristic::PROPERTY_WRITE
    );


  pControlCharacteristic->setCallbacks(
    new ControlCallbacks()
  );


  // ----------------------------------------------------------

  pService->start();


  BLEAdvertising* pAdvertising =
    BLEDevice::getAdvertising();


  pAdvertising->addServiceUUID(
    SERVICE_UUID
  );

  pAdvertising->setScanResponse(
    true
  );


  BLEDevice::startAdvertising();


  Serial.println("# BLE_READY");
}


// ============================================================
// Serial Command
// ============================================================

void checkSerialCommand() {

  static String command = "";


  while (Serial.available()) {

    char c =
      Serial.read();


    if (
      c == '\n' ||
      c == '\r'
    ) {

      command.trim();
      command.toUpperCase();


      if (command == "CAL") {

        calibrationRequested = true;
      }


      command = "";

    } else {

      command += c;
    }
  }
}


// ============================================================
// Setup
// ============================================================

void setup() {

  Serial.begin(115200);

  delay(500);


  Serial.println();
  Serial.println("# YORI Flex Firmware v1.0");
  Serial.println("# STARTING");


  // ----------------------------------------------------------
  // I2C
  // ----------------------------------------------------------

  Wire.begin(
    SDA_PIN,
    SCL_PIN
  );

  Wire.setClock(
    400000
  );


  // ----------------------------------------------------------
  // MPU Initialization
  // ----------------------------------------------------------

  bool t3OK =
    initMPU(CH_T3);

  bool t12OK =
    initMPU(CH_T12);

  bool s1OK =
    initMPU(CH_S1);


  Serial.print("# MPU_T3,");
  Serial.println(
    t3OK ? "OK" : "ERROR"
  );


  Serial.print("# MPU_T12,");
  Serial.println(
    t12OK ? "OK" : "ERROR"
  );


  Serial.print("# MPU_S1,");
  Serial.println(
    s1OK ? "OK" : "ERROR"
  );


  // ----------------------------------------------------------
  // DFR1184
  // ----------------------------------------------------------

  selectChannel(CH_EMG);

  delay(20);


  adcOK =
    ads1115.begin();


  Serial.print("# DFR1184,");

  Serial.println(
    adcOK ? "OK" : "ERROR"
  );


  // ----------------------------------------------------------
  // BLE
  // ----------------------------------------------------------

  initBLE();


  // ----------------------------------------------------------
  // Automatic calibration
  // ----------------------------------------------------------

  calibrateAll();


  // ----------------------------------------------------------
  // CSV Header
  // ----------------------------------------------------------

  Serial.println(
    "seq,time_ms,"
    "t3_ax,t3_ay,t3_az,"
    "t3_gx,t3_gy,t3_gz,"
    "t3_roll,t3_pitch,"
    "t12_ax,t12_ay,t12_az,"
    "t12_gx,t12_gy,t12_gz,"
    "t12_roll,t12_pitch,"
    "s1_ax,s1_ay,s1_az,"
    "s1_gx,s1_gy,s1_gz,"
    "s1_roll,s1_pitch,"
    "emg1_mv,emg2_mv"
  );


  lastSampleTime =
    millis();
}


// ============================================================
// Main Loop
// ============================================================

void loop() {

  // ----------------------------------------------------------
  // Serial commands
  // ----------------------------------------------------------

  checkSerialCommand();


  // ----------------------------------------------------------
  // Calibration request
  // ----------------------------------------------------------

  if (calibrationRequested) {

    calibrationRequested = false;

    calibrateAll();

    lastSampleTime =
      millis();

    return;
  }


  // ----------------------------------------------------------
  // 20 Hz sampling
  // ----------------------------------------------------------

  unsigned long now =
    millis();


  if (
    now - lastSampleTime <
    SAMPLE_INTERVAL_MS
  ) {

    return;
  }


  lastSampleTime =
    now;


  IMUData t3;
  IMUData t12;
  IMUData s1;


  bool t3Read =
    readIMU(
      CH_T3,
      t3
    );


  bool t12Read =
    readIMU(
      CH_T12,
      t12
    );


  bool s1Read =
    readIMU(
      CH_S1,
      s1
    );


  if (
    !t3Read ||
    !t12Read ||
    !s1Read
  ) {

    Serial.println(
      "# IMU_READ_ERROR"
    );

    return;
  }


  // ----------------------------------------------------------
  // Apply starting-position calibration
  // ----------------------------------------------------------

  t3.roll =
    angleDiff(
      t3.roll,
      zeroT3.roll
    );

  t3.pitch =
    angleDiff(
      t3.pitch,
      zeroT3.pitch
    );


  t12.roll =
    angleDiff(
      t12.roll,
      zeroT12.roll
    );

  t12.pitch =
    angleDiff(
      t12.pitch,
      zeroT12.pitch
    );


  s1.roll =
    angleDiff(
      s1.roll,
      zeroS1.roll
    );

  s1.pitch =
    angleDiff(
      s1.pitch,
      zeroS1.pitch
    );


  // ----------------------------------------------------------
  // EMG
  // ----------------------------------------------------------

  float emg1 =
    readEMG(1);

  float emg2 =
    readEMG(2);


  // ==========================================================
  // USB Serial -> Python
  // ==========================================================

  Serial.print(sequenceNumber);
  Serial.print(",");

  Serial.print(now);
  Serial.print(",");


  // T3
  Serial.print(t3.ax, 5);
  Serial.print(",");

  Serial.print(t3.ay, 5);
  Serial.print(",");

  Serial.print(t3.az, 5);
  Serial.print(",");

  Serial.print(t3.gx, 3);
  Serial.print(",");

  Serial.print(t3.gy, 3);
  Serial.print(",");

  Serial.print(t3.gz, 3);
  Serial.print(",");

  Serial.print(t3.roll, 3);
  Serial.print(",");

  Serial.print(t3.pitch, 3);
  Serial.print(",");


  // T12
  Serial.print(t12.ax, 5);
  Serial.print(",");

  Serial.print(t12.ay, 5);
  Serial.print(",");

  Serial.print(t12.az, 5);
  Serial.print(",");

  Serial.print(t12.gx, 3);
  Serial.print(",");

  Serial.print(t12.gy, 3);
  Serial.print(",");

  Serial.print(t12.gz, 3);
  Serial.print(",");

  Serial.print(t12.roll, 3);
  Serial.print(",");

  Serial.print(t12.pitch, 3);
  Serial.print(",");


  // S1
  Serial.print(s1.ax, 5);
  Serial.print(",");

  Serial.print(s1.ay, 5);
  Serial.print(",");

  Serial.print(s1.az, 5);
  Serial.print(",");

  Serial.print(s1.gx, 3);
  Serial.print(",");

  Serial.print(s1.gy, 3);
  Serial.print(",");

  Serial.print(s1.gz, 3);
  Serial.print(",");

  Serial.print(s1.roll, 3);
  Serial.print(",");

  Serial.print(s1.pitch, 3);
  Serial.print(",");


  // EMG
  Serial.print(emg1, 2);
  Serial.print(",");

  Serial.println(emg2, 2);


  // ==========================================================
  // BLE Main Packet
  // ==========================================================

  MainPacket mainPacket;


  mainPacket.sequence =
    sequenceNumber;


  // degrees ×100
  mainPacket.t3Roll =
    scaleValue(
      t3.roll,
      100.0f
    );

  mainPacket.t3Pitch =
    scaleValue(
      t3.pitch,
      100.0f
    );


  mainPacket.t12Roll =
    scaleValue(
      t12.roll,
      100.0f
    );

  mainPacket.t12Pitch =
    scaleValue(
      t12.pitch,
      100.0f
    );


  mainPacket.s1Roll =
    scaleValue(
      s1.roll,
      100.0f
    );

  mainPacket.s1Pitch =
    scaleValue(
      s1.pitch,
      100.0f
    );


  // EMG in mV
  mainPacket.emg1 =
    (int16_t)roundf(emg1);

  mainPacket.emg2 =
    (int16_t)roundf(emg2);


  // ==========================================================
  // BLE Gyroscope Packet
  // ==========================================================

  GyroPacket gyroPacket;


  gyroPacket.sequence =
    sequenceNumber;


  // deg/s ×10

  gyroPacket.t3x =
    scaleValue(
      t3.gx,
      10.0f
    );

  gyroPacket.t3y =
    scaleValue(
      t3.gy,
      10.0f
    );

  gyroPacket.t3z =
    scaleValue(
      t3.gz,
      10.0f
    );


  gyroPacket.t12x =
    scaleValue(
      t12.gx,
      10.0f
    );

  gyroPacket.t12y =
    scaleValue(
      t12.gy,
      10.0f
    );

  gyroPacket.t12z =
    scaleValue(
      t12.gz,
      10.0f
    );


  gyroPacket.s1x =
    scaleValue(
      s1.gx,
      10.0f
    );

  gyroPacket.s1y =
    scaleValue(
      s1.gy,
      10.0f
    );

  gyroPacket.s1z =
    scaleValue(
      s1.gz,
      10.0f
    );


  // ==========================================================
  // BLE Accelerometer Packet
  // ==========================================================

  AccelPacket accelPacket;


  accelPacket.sequence =
    sequenceNumber;


  // g ×10000

  accelPacket.t3x =
    scaleValue(
      t3.ax,
      10000.0f
    );

  accelPacket.t3y =
    scaleValue(
      t3.ay,
      10000.0f
    );

  accelPacket.t3z =
    scaleValue(
      t3.az,
      10000.0f
    );


  accelPacket.t12x =
    scaleValue(
      t12.ax,
      10000.0f
    );

  accelPacket.t12y =
    scaleValue(
      t12.ay,
      10000.0f
    );

  accelPacket.t12z =
    scaleValue(
      t12.az,
      10000.0f
    );


  accelPacket.s1x =
    scaleValue(
      s1.ax,
      10000.0f
    );

  accelPacket.s1y =
    scaleValue(
      s1.ay,
      10000.0f
    );

  accelPacket.s1z =
    scaleValue(
      s1.az,
      10000.0f
    );


  // ==========================================================
  // BLE Notify
  // ==========================================================

  if (deviceConnected) {

    pDataCharacteristic->setValue(
      (uint8_t*)&mainPacket,
      sizeof(mainPacket)
    );

    pDataCharacteristic->notify();


    pGyroCharacteristic->setValue(
      (uint8_t*)&gyroPacket,
      sizeof(gyroPacket)
    );

    pGyroCharacteristic->notify();


    pAccelCharacteristic->setValue(
      (uint8_t*)&accelPacket,
      sizeof(accelPacket)
    );

    pAccelCharacteristic->notify();
  }


  sequenceNumber++;
}
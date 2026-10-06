#pragma once
#include <Arduino.h>
#include <SPI.h>
#include "storage.h"

namespace compi {

// Driver mínimo para chips de flash SPI compatibles con Winbond W25Qxx,
// pensado para el 25Q32FVSIG (W25Q32FV, 32 Mbit / 4 MiB). Habla los comandos
// del chip directamente, sin librerías externas.
//
// Cada slot = 17 sectores de 4 KiB (69632 bytes):
//   byte 0            marca de uso (0xA5 = usado)
//   bytes 1..15       metadatos (storage.h SLOT_META_SIZE: categoria + nombre)
//   bytes 16..65551   imagen de 64 KiB (PROGRAM_SIZE)
class SpiFlashStorage : public IProgramStorage {
public:
    explicit SpiFlashStorage(uint8_t csPin);

    bool init() override;
    bool slotUsed(int slot) override;
    bool loadProgram(int slot, uint8_t* dest) override;
    bool previewProgram(int slot, uint8_t* dest, uint32_t len) override;
    bool saveProgram(int slot, const uint8_t* src, const uint8_t* meta) override;
    bool readSlotMeta(int slot, uint8_t* meta) override;
    bool deleteProgram(int slot) override;
    bool readEeprom(int slot, uint8_t* dest) override;
    bool writeEeprom(int slot, const uint8_t* src) override;
    bool readSettings(uint8_t* dest) override;
    bool writeSettings(const uint8_t* src) override;

    // Diagnóstico: JEDEC ID. Para el 25Q32FVSIG: 0xEF, 0x40, 0x16.
    void readJedecId(uint8_t* manufacturer, uint8_t* memType, uint8_t* capacity);

private:
    // Deep power-down (comando 0xB9): baja el consumo en reposo de ~15 µA a
    // ~1 µA. El chip solo se despierta (0xAB) para leer/escribir un slot, cosa
    // rara. wake()/sleep() llevan un contador de anidamiento para que las
    // llamadas internas (loadProgram -> slotUsed) no lo despierten/duerman a
    // destiempo. Fuera de estas operaciones el chip está siempre dormido.
    void wake();
    void sleep();
    int awakeDepth_ = 0;

    static constexpr uint32_t SECTOR_SIZE      = 4096;
    static constexpr uint32_t SECTORS_PER_SLOT = 17;
    static constexpr uint32_t SLOT_STRIDE      = SECTOR_SIZE * SECTORS_PER_SLOT; // 69632
    static constexpr uint32_t IMAGE_OFFSET     = 16;   // la imagen empieza aquí
    static constexpr uint8_t  USED_MARK        = 0xA5;

    // --- EEPROM emulada (storage.h EEPROM_SLOT_SIZE bytes/slot) -----------
    // Justo despues del ultimo slot de programa, en lo que sobra del chip de
    // 4 MiB (60*SLOT_STRIDE = 4177920; 4194304-4177920 = 16384 = exactamente
    // 60*EEPROM_SLOT_SIZE, sin desperdiciar nada). SECTOR_SIZE/EEPROM_SLOT_
    // SIZE = 16 slots por sector de borrado: cada escritura solo toca (lee,
    // borra, reescribe) el sector de 4 KiB que contiene ESE slot, no los 4
    // sectores enteros de la zona -- 15 de los otros 59 slots como mucho
    // comparten sector con el que se esta escribiendo.
    static constexpr uint32_t EEPROM_BASE_ADDR    = MAX_PROGRAM_SLOTS * SLOT_STRIDE; // 0x3FC000
    static constexpr uint32_t EEPROM_SLOTS_PER_SECTOR = SECTOR_SIZE / EEPROM_SLOT_SIZE; // 16
    // Ajustes globales (storage.h SETTINGS_SIZE): justo tras la EEPROM del
    // ultimo slot, en el KiB libre del final del chip (0x3FFC00). Comparte
    // sector de borrado con la EEPROM de los slots 48-59 -- se graba con el
    // mismo leer-parchear-borrar-reescribir del sector que writeEeprom.
    static constexpr uint32_t SETTINGS_ADDR = EEPROM_BASE_ADDR + MAX_PROGRAM_SLOTS * EEPROM_SLOT_SIZE; // 0x3FFC00

    uint8_t csPin_;

    void select();
    void deselect();
    void writeEnable();
    bool waitBusy(unsigned long timeoutMs = 3000);
    void eraseSector(uint32_t addr);
    void writeBytes(uint32_t addr, const uint8_t* data, uint32_t len);
    void readBytes(uint32_t addr, uint8_t* buffer, uint32_t len);
    void sendAddress24(uint32_t addr);
    void patchSector(uint32_t addr, const uint8_t* src, uint32_t len);

    uint32_t slotAddr(int slot) const { return (uint32_t)slot * SLOT_STRIDE; }
    bool validSlot(int slot) const { return slot >= 0 && (size_t)slot < MAX_PROGRAM_SLOTS; }
    uint32_t eepromAddr(int slot) const {
        return EEPROM_BASE_ADDR + (uint32_t)slot * EEPROM_SLOT_SIZE;
    }
};

} // namespace compi

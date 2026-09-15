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
//   bytes 1..15       reservados
//   bytes 16..65551   imagen de 64 KiB (PROGRAM_SIZE)
class SpiFlashStorage : public IProgramStorage {
public:
    explicit SpiFlashStorage(uint8_t csPin);

    bool init() override;
    bool slotUsed(int slot) override;
    bool loadProgram(int slot, uint8_t* dest) override;
    bool previewProgram(int slot, uint8_t* dest, uint32_t len) override;
    bool saveProgram(int slot, const uint8_t* src) override;
    bool deleteProgram(int slot) override;

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

    uint8_t csPin_;

    void select();
    void deselect();
    void writeEnable();
    bool waitBusy(unsigned long timeoutMs = 3000);
    void eraseSector(uint32_t addr);
    void writeBytes(uint32_t addr, const uint8_t* data, uint32_t len);
    void readBytes(uint32_t addr, uint8_t* buffer, uint32_t len);
    void sendAddress24(uint32_t addr);

    uint32_t slotAddr(int slot) const { return (uint32_t)slot * SLOT_STRIDE; }
    bool validSlot(int slot) const { return slot >= 0 && (size_t)slot < MAX_PROGRAM_SLOTS; }
};

} // namespace compi

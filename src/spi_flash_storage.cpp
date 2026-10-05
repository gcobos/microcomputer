#include "spi_flash_storage.h"
#include <string.h>

namespace compi {

namespace {
constexpr uint8_t CMD_WRITE_ENABLE = 0x06;
constexpr uint8_t CMD_READ_STATUS1 = 0x05;
constexpr uint8_t CMD_PAGE_PROGRAM = 0x02;
constexpr uint8_t CMD_SECTOR_ERASE = 0x20;
constexpr uint8_t CMD_READ_DATA    = 0x03;
constexpr uint8_t CMD_JEDEC_ID     = 0x9F;
constexpr uint8_t CMD_POWER_DOWN   = 0xB9;   // deep power-down (~1 µA)
constexpr uint8_t CMD_RELEASE_PD   = 0xAB;   // salir de deep power-down
constexpr uint8_t STATUS_BUSY_BIT  = 0x01;
constexpr uint32_t PAGE_SIZE       = 256;

// 8 MHz es conservador; el chip admite bastante más. No hace falta apurar.
SPISettings kFlashSpiSettings(8000000, MSBFIRST, SPI_MODE0);
} // namespace

SpiFlashStorage::SpiFlashStorage(uint8_t csPin) : csPin_(csPin) {}

void SpiFlashStorage::select() {
    SPI.beginTransaction(kFlashSpiSettings);
    digitalWrite(csPin_, LOW);
}

void SpiFlashStorage::deselect() {
    digitalWrite(csPin_, HIGH);
    SPI.endTransaction();
}

void SpiFlashStorage::sendAddress24(uint32_t addr) {
    SPI.transfer((uint8_t)((addr >> 16) & 0xFF));
    SPI.transfer((uint8_t)((addr >> 8) & 0xFF));
    SPI.transfer((uint8_t)(addr & 0xFF));
}

void SpiFlashStorage::writeEnable() {
    select();
    SPI.transfer(CMD_WRITE_ENABLE);
    deselect();
}

void SpiFlashStorage::wake() {
    if (awakeDepth_++ > 0) return;          // ya estaba despierto (llamada anidada)
    select();
    SPI.transfer(CMD_RELEASE_PD);
    deselect();
    delayMicroseconds(5);                   // tRES1: espera a que responda
}

void SpiFlashStorage::sleep() {
    if (awakeDepth_ > 0) --awakeDepth_;
    if (awakeDepth_ > 0) return;
    select();
    SPI.transfer(CMD_POWER_DOWN);
    deselect();
    delayMicroseconds(5);                   // tDP: termina de entrar en reposo
}

bool SpiFlashStorage::waitBusy(unsigned long timeoutMs) {
    unsigned long start = millis();
    while (true) {
        select();
        SPI.transfer(CMD_READ_STATUS1);
        uint8_t status = SPI.transfer(0xFF);
        deselect();
        if ((status & STATUS_BUSY_BIT) == 0) return true;
        if (millis() - start > timeoutMs) return false; // nunca colgarse
    }
}

void SpiFlashStorage::eraseSector(uint32_t addr) {
    writeEnable();
    select();
    SPI.transfer(CMD_SECTOR_ERASE);
    sendAddress24(addr);
    deselect();
    waitBusy();
}

void SpiFlashStorage::writeBytes(uint32_t addr, const uint8_t* data, uint32_t len) {
    uint32_t written = 0;
    while (written < len) {
        // Un Page Program no cruza un límite de página de 256 bytes.
        uint32_t offsetInPage = (addr + written) % PAGE_SIZE;
        uint32_t chunk = PAGE_SIZE - offsetInPage;
        if (chunk > len - written) chunk = len - written;

        writeEnable();
        select();
        SPI.transfer(CMD_PAGE_PROGRAM);
        sendAddress24(addr + written);
        for (uint32_t i = 0; i < chunk; ++i) {
            SPI.transfer(data[written + i]);
        }
        deselect();
        waitBusy();

        written += chunk;
    }
}

void SpiFlashStorage::readBytes(uint32_t addr, uint8_t* buffer, uint32_t len) {
    select();
    SPI.transfer(CMD_READ_DATA);
    sendAddress24(addr);
    for (uint32_t i = 0; i < len; ++i) {
        buffer[i] = SPI.transfer(0xFF);
    }
    deselect();
}

void SpiFlashStorage::readJedecId(uint8_t* manufacturer, uint8_t* memType, uint8_t* capacity) {
    select();
    SPI.transfer(CMD_JEDEC_ID);
    *manufacturer = SPI.transfer(0xFF);
    *memType      = SPI.transfer(0xFF);
    *capacity     = SPI.transfer(0xFF);
    deselect();
}

bool SpiFlashStorage::init() {
    pinMode(csPin_, OUTPUT);
    digitalWrite(csPin_, HIGH);
    SPI.begin();

    // Por si el chip venía en deep power-down de un reset anterior.
    select();
    SPI.transfer(CMD_RELEASE_PD);
    deselect();
    delayMicroseconds(5);

    uint8_t manufacturer, memType, capacity;
    readJedecId(&manufacturer, &memType, &capacity);
    (void)memType;
    (void)capacity;

    // Deja el chip dormido: solo se despierta para leer/escribir un slot.
    // La espera tDP (hasta 3 us en el W25Q32) es imprescindible: setup()
    // llama a loadProgram(0) justo después, y un 0xAB (despertar) que llegue
    // mientras el chip todavía está entrando en reposo se ignora -- el chip
    // se queda dormido, la marca del slot se lee como basura y el slot 0 no
    // se carga (bug real reportado: a veces, tras reset, la RAM quedaba
    // entera en NOP; con "Cargar" a mano sí funcionaba).
    select();
    SPI.transfer(CMD_POWER_DOWN);
    deselect();
    delayMicroseconds(5);

    // Winbond = 0xEF. Con otro fabricante compatible, ajustar esta comprobación.
    return manufacturer == 0xEF;
}

bool SpiFlashStorage::slotUsed(int slot) {
    if (!validSlot(slot)) return false;
    wake();
    uint8_t mark = 0;
    readBytes(slotAddr(slot), &mark, 1);
    sleep();
    return mark == USED_MARK;
}

bool SpiFlashStorage::loadProgram(int slot, uint8_t* dest) {
    wake();
    bool ok = slotUsed(slot);
    if (ok) readBytes(slotAddr(slot) + IMAGE_OFFSET, dest, (uint32_t)PROGRAM_SIZE);
    sleep();
    return ok;
}

bool SpiFlashStorage::previewProgram(int slot, uint8_t* dest, uint32_t len) {
    wake();
    bool ok = slotUsed(slot);
    if (ok) readBytes(slotAddr(slot) + IMAGE_OFFSET, dest, len);
    sleep();
    return ok;
}

bool SpiFlashStorage::saveProgram(int slot, const uint8_t* src) {
    if (!validSlot(slot)) return false;
    wake();

    uint32_t base = slotAddr(slot);
    for (uint32_t i = 0; i < SECTORS_PER_SLOT; ++i) {
        eraseSector(base + i * SECTOR_SIZE);
    }
    uint8_t mark = USED_MARK;
    writeBytes(base, &mark, 1);
    writeBytes(base + IMAGE_OFFSET, src, (uint32_t)PROGRAM_SIZE);

    sleep();
    return true;
}

bool SpiFlashStorage::deleteProgram(int slot) {
    if (!validSlot(slot)) return false;
    wake();
    uint32_t base = slotAddr(slot);
    for (uint32_t i = 0; i < SECTORS_PER_SLOT; ++i) {
        eraseSector(base + i * SECTOR_SIZE);
    }
    sleep();
    return true; // marca a 0xFF = libre
}

bool SpiFlashStorage::readEeprom(int slot, uint8_t* dest) {
    if (!validSlot(slot)) return false;
    wake();
    readBytes(eepromAddr(slot), dest, (uint32_t)EEPROM_SLOT_SIZE);
    sleep();
    return true;
}

bool SpiFlashStorage::writeEeprom(int slot, const uint8_t* src) {
    if (!validSlot(slot)) return false;
    wake();

    // Unico modo de tocar un solo byte en NOR flash sin perder el resto:
    // leer el sector ENTERO que contiene este slot (hasta 16 slots viven
    // ahi, ver EEPROM_SLOTS_PER_SECTOR), parchear solo los EEPROM_SLOT_SIZE
    // bytes de este slot, borrar ese sector y reescribirlo entero. `sector`
    // static (no en la pila): 4096 bytes es demasiado para arriesgarse en
    // una pila de tarea de Arduino, y esta funcion nunca se reentra (single
    // task, ver el resto del driver).
    static uint8_t sector[SECTOR_SIZE];
    uint32_t addr = eepromAddr(slot);
    uint32_t sectorAddr = addr - (addr % SECTOR_SIZE);
    uint32_t offsetInSector = addr - sectorAddr;

    readBytes(sectorAddr, sector, SECTOR_SIZE);
    memcpy(sector + offsetInSector, src, EEPROM_SLOT_SIZE);
    eraseSector(sectorAddr);
    writeBytes(sectorAddr, sector, SECTOR_SIZE);

    sleep();
    return true;
}

} // namespace compi

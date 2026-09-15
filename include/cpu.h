#pragma once
#include <stdint.h>
#include <stddef.h>
#include "isa.h"

namespace compi {

// RAM real de la CPU. Las instrucciones usan direcciones de 16 bits
// (LDA/STA/JMP/CALL); con kMemSize = 65536 se cubre todo el espacio y no
// hay recorte. maskAddr() sigue enmascarando con (kMemSize - 1) para poder
// reducirlo si hiciera falta, así que este valor DEBE ser potencia de dos.
//
// NOTA: no se puede llamar MEM_SIZE — lwIP (que entra por Arduino.h en los
// SoC con USB-CDC nativo, como el ESP32-C3) define esa macro y rompe la
// compilación.
constexpr size_t kMemSize = 65536;

struct Registers {
    uint16_t AX = 0, BX = 0, CX = 0, DX = 0;

    uint8_t get8(uint8_t reg) const;
    void set8(uint8_t reg, uint8_t value);

    // Par de 16 bits por código Reg16 (isa.h): para el direccionamiento
    // indirecto de LDA/STA/IN/OUT (OP_LDAR/OP_STAR/OP_INR/OP_OUTR).
    uint16_t get16(uint8_t pairCode) const;
};

// Núcleo de la CPU, sin ninguna dependencia de hardware. El panel frontal
// (encoders, pantalla SPI, botones) y la flash SPI son responsabilidad de
// capas superiores: aquí solo vive la máquina.
class Cpu {
public:
    Cpu();

    void reset();

    // Pone toda la RAM a 0. reset() NO toca la memoria (solo el estado de la
    // CPU); esto es para cargar un programa "limpio" desde la flash.
    void clearMemory();

    // Rellena un rango de memoria con un valor.
    void fillMem(uint16_t addr, uint16_t len, uint8_t value);

    // Acceso directo a los 65536 bytes de RAM, para guardar/cargar la imagen
    // completa en la flash sin buffer intermedio.
    uint8_t*       ram()       { return memory_; }
    const uint8_t* ram() const { return memory_; }

    // Escribe bytes en memoria (para programar manualmente o cargar un
    // programa recuperado de la flash).
    void loadBytes(uint16_t addr, const uint8_t* data, uint16_t len);

    // Lee un bloque de memoria de una vez (para volcar un programa a la
    // flash antes de guardarlo).
    void dumpBytes(uint16_t addr, uint8_t* buffer, uint16_t len) const;

    // Ejecuta una única instrucción. Devuelve false si la CPU quedó parada (HALT).
    bool step();

    // Ejecuta hasta HALT o hasta maxSteps instrucciones (maxSteps<0 = sin límite).
    void run(int32_t maxSteps = -1);

    bool halted() const { return halted_; }

    // Ganchos de E/S: el host decide qué hace cada puerto. Espacio de puertos
    // de 16 bits (65536 puertos), independiente de la RAM. Sin gancho, IN
    // devuelve 0 y OUT no hace nada.
    using PortReadFn  = uint8_t (*)(uint16_t port);
    using PortWriteFn = void (*)(uint16_t port, uint8_t value);
    void setPortRead(PortReadFn fn)   { portRead_ = fn; }
    void setPortWrite(PortWriteFn fn) { portWrite_ = fn; }

    // Estado observable, para el panel frontal / depuración.
    uint8_t  mem(uint16_t addr) const { return memory_[maskAddr(addr)]; }
    uint16_t pc() const { return pc_; }
    uint16_t sp() const { return sp_; }
    uint8_t  flags() const { return flags_; }
    const Registers& regs() const { return regs_; }

    void setPc(uint16_t v) { pc_ = v; }
    void pokeMem(uint16_t addr, uint8_t value) { memory_[maskAddr(addr)] = value; }
    void setReg8(uint8_t reg, uint8_t value) { regs_.set8(reg, value); }

private:
    static uint16_t maskAddr(uint16_t addr) { return (uint16_t)(addr & (kMemSize - 1)); }

    uint8_t fetch8();
    uint16_t fetch16();
    void push8(uint8_t v);
    uint8_t pop8();
    uint8_t updateFlagsArith(uint8_t a, uint8_t b, bool isSub);
    void updateFlagsLogic(uint8_t result);
    // Aplica una operación de la ALU (compi::AluOp) a (a, b), actualiza los
    // flags y devuelve el nuevo valor del destino (para CMP devuelve a).
    uint8_t aluOp(uint8_t op, uint8_t a, uint8_t b);
    bool testCond(uint8_t cond) const;

    uint8_t memory_[kMemSize];
    Registers regs_;
    uint16_t pc_ = 0;
    uint16_t sp_ = 0;
    uint8_t  flags_ = 0;
    bool halted_ = false;

    PortReadFn  portRead_ = nullptr;
    PortWriteFn portWrite_ = nullptr;
};

} // namespace compi

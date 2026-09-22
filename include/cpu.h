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

// AX/BX/CX/DX y sus 8 mitades de 8 bits son la MISMA memoria (union): así
// get8/set8/get16 son un indexado directo de array en vez de un switch de
// 8/4 casos -- son de las funciones mas llamadas de todo el interprete
// (varias veces por CADA instruccion emulada), y al definirlas aqui mismo
// (en la clase) quedan inline. Requiere little-endian (bytes[0] = byte bajo
// de words[0] = AL, ver Reg8 en isa.h): tanto el ESP32-C3 (RISC-V) como
// cualquier maquina x86_64 donde se compile nativo (docs/firmware.md) lo
// son. Verificado por fuerza bruta contra la version anterior (switch sobre
// AX/BX/CX/DX con nombre propio) en las 65536 combinaciones de registro x
// valor -- ver el historial de esta sesion.
struct Registers {
    union {
        uint16_t words[4];  // 0=AX 1=BX 2=CX 3=DX (orden de Reg16, isa.h)
        uint8_t  bytes[8];  // 0=AL 1=AH 2=BL ... 7=DH (orden de Reg8, isa.h)
    };

    Registers() : words{0, 0, 0, 0} {}

    // AX/BX/CX/DX ya no son campos con nombre (ver el union de arriba):
    // display.cpp los lee a través de estos accesores.
    uint16_t AX() const { return words[0]; }
    uint16_t BX() const { return words[1]; }
    uint16_t CX() const { return words[2]; }
    uint16_t DX() const { return words[3]; }

    uint8_t get8(uint8_t reg) const { return bytes[reg & 0x07]; }
    void set8(uint8_t reg, uint8_t value) { bytes[reg & 0x07] = value; }

    // Par de 16 bits por código Reg16 (isa.h): para el direccionamiento
    // indirecto de LDA/STA/IN/OUT (OP_LDAR/OP_STAR/OP_INR/OP_OUTR).
    uint16_t get16(uint8_t pairCode) const { return words[pairCode & 0x03]; }
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
    bool testCond(uint8_t cond) const;
    uint8_t updateFlagsArith(uint8_t a, uint8_t b, bool isSub);
    void updateFlagsLogic(uint8_t result);
    // SHR/SHL de N bits (1-8) de una vez: OP_SHR/OP_SHL llaman a estas con
    // n=1 (asi el caso de 1 bit es identico, bit a bit, al de siempre).
    // Flags: C = el bit que sale en el ULTIMO de los N desplazamientos; Z/N
    // del resultado final; V de SHR = bit 7 del valor ANTES de esta
    // instruccion (no de cada paso interno -- "previo" se refiere a la
    // instruccion completa, que aqui es una sola aunque desplace N bits);
    // V de SHL = igual formula de siempre (carry != signo), aplicada al
    // ultimo paso.
    void doShr(uint8_t reg, uint8_t n);
    void doShl(uint8_t reg, uint8_t n);
    // Aplica una operación de la ALU (compi::AluOp) a (a, b), actualiza los
    // flags y devuelve el nuevo valor del destino (para CMP devuelve a).
    // NO esta forzada a inline: probado en el benchmark real, integrarla en
    // step()/run() (duplicandola en 3 sitios) salio ~12% MAS LENTA, no mas
    // rapida -- el codigo resultante es notablemente mas grande y parece
    // perjudicar el aprovechamiento de la cache de instrucciones del
    // RV32IMC mas de lo que ahorra en llamadas evitadas. Ver el historial de
    // esta sesion (N=0x1EE=494 con aluOp aparte, N=0x1B2=434 integrada).
    uint8_t aluOp(uint8_t op, uint8_t a, uint8_t b);

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

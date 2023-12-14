; MMIO registers
; Memory-Mapped Input/Output registers
PPUCTRL   = $2000
PPUMASK   = $2001
PPUSTATUS = $2002
PPUSCROLL = $2005
PPUADDR   = $2006
PPUDATA   = $2007

.segment "HEADER"
;            EOF
.byte "NES", $1A
.byte 2         ; Number of 16KB PRG-ROM banks
.byte 1         ; Number of 8KB CHR-ROM banks
.byte %00000001 ; Vertical mirroring, no save RAM, no mapper
.byte %00000000 ; No special-case flags set, no mapper
.byte 0         ; No PRG-RAM present
.byte %00000000 ; NTSC format

.segment "CHR"
.incbin "../res/pattern_tables.chr" ; include the binary file created with NEXXT

; we need to keep track of the scroll position in RAM
.segment "ZEROPAGE" ; zero page RAM access is the fastest
ppu_ctrl: .res 1 ; keep track of selected nametable
x_scroll: .res 1 ; range [0,255]
; For *Post-Indexed Indirect* addressing mode
lobyte: .res 1 ; little-endian: low byte first
hibyte: .res 1

.segment "RODATA" ; Prepare data separated from the logic in this segment
; but, we still have to copy them to their PPU's VRAM place later
background_palette: .incbin "../res/background.pal"
nametable_0: .incbin "../res/nametable_0.nam"
nametable_1: .incbin "../res/nametable_1.nam"

.segment "CODE"
.export irq_handler
.proc irq_handler ; 6502 requires this handler
  RTI ; Just exit, we have no use for this handler in this program.
.endproc

.export nmi_handler
.proc nmi_handler ; 6502 requires this handler
  ; We need to service NMIs when drawing non-static backgrounds

  ; NMIs can happen at any time, so we need to back up the registers
  ; SR (status register) is automatically pushed to the stack,
  ; but we need to backup A, X and Y.
  PHA ; push A to the stack, which still contains A's value
  ; There is no instruction to push X or Y, but there are to copy them to A
  TXA ; copy X to A
  PHA ; push A to the stack, which contains X's value
  TYA ; copy Y to A
  PHA ; push A to the stack, which contains Y's value

  ; with non-static background, we avoid visual artifacts
  ; by enabling PPU's drawing during vblank (inside NMI)
  ;     BGRsbMmG
  LDA #%00001010
  STA PPUMASK ; Enable background drawing and leftmost 8 pixels of screen
  BIT PPUSTATUS ; Clear vblank flag and w
  LDA x_scroll ; load value from zero page RAM
  STA PPUSCROLL ; X position
  LDA #0 ; load 0
  STA PPUSCROLL ; Y position
  LDA ppu_ctrl ; load value from zero page RAM
  STA PPUCTRL ; select nametable
  INC x_scroll ; increment value in zero page RAM for next frame/vblank/NMI
  BNE keep_selected_nametable ; skip next two lines until overflow
  EOR #%00000001 ; flip bit 0 to select the next nametable
  STA ppu_ctrl ; save selected nametabe for next frame/vblank/NMI
  keep_selected_nametable: ; branch here until x_scroll overflows

  ; Restore the registers before returning
  PLA ; pull value from the stack (which was Y's value)
  TAY ; copy A to Y
  PLA ; pull value from the stack (which was X's value)
  TAX ; copy A to X
  PLA ; pull value  from the stack (which was A's value)
  ; SR (status register) will be automatically pulled from the stack after RTI
  RTI ; return and resume to the main thread
.endproc

.export reset_handler
.proc reset_handler ; 6502 requires this handler
  SEI ; Deactivate IRQ (non-NMI interrupts)
  CLD ; Deactivate non-existing decimal mode
  ; NES CPU is a MOS 6502 clone without decimal mode
  LDX #%00000000
  STX PPUCTRL ; PPU is unstable on boot, ignore NMI for now
  STX PPUMASK ; Deactivate PPU drawing, so CPU can safely write to PPU's VRAM
  BIT PPUSTATUS ; Clear the vblank flag; its value on boot cannot be trusted
  vblankwait1: ; PPU unstable on boot, wait for vblank
    BIT PPUSTATUS ; Clear the vblank flag;
    ; and store its value into bit 7 of CPU status register
    BPL vblankwait1 ; repeat until bit 7 of CPU status register is set (1)
  vblankwait2: ; PPU still unstable, wait for another vblank
    BIT PPUSTATUS
    BPL vblankwait2
  ; PPU should be stable enough now

  ; RAM contents on boot cannot be trusted (visual artifacts)
  ; But, we don't need to clear them
  ; since we are going to override the two nametables
  ; CPU registers size is 1 byte, but addresses size is 2 bytes
  BIT PPUSTATUS ; Clear w register
  ; Address $2000
  LDA #$20
  STA PPUADDR
  LDA #$00
  STA PPUADDR
  ; Index registers overflow after 255,
  ; we need *Post-Indexed Indirect* addressing mode to copy 2048 bytes
  ; 2048 bytes = 8 pages * 256 bytes
  LDA #.LOBYTE(nametable_0)
  STA lobyte
  LDA #.HIBYTE(nametable_0)
  STA hibyte
  LDY #0 ; loop index
  copy_nametables:
    copy_page:
      LDA (lobyte),y ; *Post-Indexed Indirect* -> (HIBYTE_LOBYTE + Y)
      STA PPUDATA ; copy 1 byte
      INY
      BNE copy_page ; repeat until Y overflows
    INC hibyte ; next page
    LDA hibyte
    CMP #.HIBYTE(nametable_0) + 8
    BNE copy_nametables ; repeat until 8 pages are copied

  ; Background palette is at PPU's VRAM address 3f00
  LDX #$3f
  STX PPUADDR
  LDX #$00
  STX PPUADDR

  LDX #0 ; loop index
  copy_palette:
    LDA background_palette,X ; load color
    STA PPUDATA ; store color
    INX
    CPX #4
    BNE copy_palette ; copy 4 colors

  LDA #0
  STA x_scroll ; start at position 0
  ;     VPHBSINN
  LDA #%10000000
  STA ppu_ctrl ; start at nametable 0
  BIT PPUSTATUS ; clear expired vblank
  STA PPUCTRL ; start serving NMIs

  forever:
    JMP forever ; Make CPU wait forever, while PPU keeps drawing frames forever
.endproc

.segment "VECTORS" ; 6502 requires this segment
.addr nmi_handler, reset_handler, irq_handler

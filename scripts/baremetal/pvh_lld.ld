ENTRY(_start)
PHDRS
{
  note PT_NOTE FLAGS(4);
  text PT_LOAD FLAGS(5);
  data PT_LOAD FLAGS(6);
}
SECTIONS
{
  . = 0x01000000;

  .note.Xen ALIGN(4) : {
    KEEP(*(.note.Xen))
  } :note

  .multiboot ALIGN(8) : {
    KEEP(*(.multiboot))
  } :text

  .text ALIGN(16) : {
    *(.text.pvh)
    *(.text .text.*)
  } :text

  .rodata ALIGN(16) : {
    *(.rodata .rodata.*)
    *(.eh_frame .eh_frame.*)
    *(.eh_frame_hdr)
  } :text

  .data ALIGN(16) : {
    *(.data .data.*)
    *(.data.rel.ro .data.rel.ro.*)
  } :data

  .bss ALIGN(4096) : {
    *(.bss.pvh)
    *(.bss .bss.* COMMON)
  } :data

  /DISCARD/ : {
    *(.debug*)
    *(.comment)
    *(.note.GNU-stack)
  }
}

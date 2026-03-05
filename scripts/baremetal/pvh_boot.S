.section .note.Xen,"a",@note
.balign 4
.long 4
.long 4
.long 18
.asciz "Xen"
.balign 4
.long pvh_start
.balign 4

.section .text.pvh,"ax"
.code32
.global pvh_start
.type pvh_start,@function
pvh_start:
    cli
    cld

    movl $stack32_top, %esp

    xorl %eax, %eax
    movl $pml4_table, %edi
    movl $3072/4, %ecx
    rep stosl

    movl $pdpt_table, %eax
    orl $0x003, %eax
    movl %eax, pml4_table

    movl $pd_table, %eax
    orl $0x003, %eax
    movl %eax, pdpt_table

    xorl %ecx, %ecx
1:
    movl %ecx, %eax
    shll $21, %eax
    orl $0x083, %eax
    movl %eax, pd_table(,%ecx,8)
    movl $0x0, pd_table+4(,%ecx,8)
    incl %ecx
    cmpl $512, %ecx
    jne 1b

    movl %cr4, %eax
    orl $0x20, %eax
    movl %eax, %cr4

    movl $pml4_table, %eax
    movl %eax, %cr3

    movl $0xC0000080, %ecx
    rdmsr
    orl $0x100, %eax
    wrmsr

    movl %cr0, %eax
    orl $0x80000001, %eax
    movl %eax, %cr0

    lgdt gdt64_desc
    ljmp $0x08, $long_mode_entry

.code64
long_mode_entry:
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movw %ax, %fs
    movw %ax, %gs

    leaq stack64_top(%rip), %rsp
    andq $-16, %rsp

    call _start

2:
    hlt
    jmp 2b

.align 16
gdt64:
    .quad 0x0000000000000000
    .quad 0x00AF9A000000FFFF
    .quad 0x00CF92000000FFFF
gdt64_end:

gdt64_desc:
    .word gdt64_end - gdt64 - 1
    .long gdt64

.section .bss.pvh,"aw",@nobits
.balign 4096
pml4_table:
    .skip 4096
pdpt_table:
    .skip 4096
pd_table:
    .skip 4096

.balign 16
stack32:
    .skip 4096
stack32_top:

.balign 16
stack64:
    .skip 16384
stack64_top:

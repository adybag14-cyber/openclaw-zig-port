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
    movl $(4096 * 6 / 4), %ecx
    rep stosl

    movl $pdpt_table, %eax
    orl $0x003, %eax
    movl %eax, pml4_table

    xorl %ecx, %ecx
1:
    movl %ecx, %edx
    shll $12, %edx
    leal pd_tables(%edx), %eax
    orl $0x003, %eax
    movl %eax, pdpt_table(,%ecx,8)
    movl $0x0, pdpt_table+4(,%ecx,8)

    xorl %ebx, %ebx
2:
    movl %ecx, %eax
    shll $9, %eax
    addl %ebx, %eax
    shll $21, %eax
    orl $0x083, %eax
    movl %ecx, %edx
    shll $12, %edx
    movl %eax, pd_tables(%edx,%ebx,8)
    movl $0x0, pd_tables+4(%edx,%ebx,8)
    incl %ebx
    cmpl $512, %ebx
    jne 2b

    incl %ecx
    cmpl $4, %ecx
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

    # Enable SSE/XMM before entering Zig runtime.
    # Clear CR0.EM/CR0.TS and set CR0.MP/CR0.NE.
    movq %cr0, %rax
    andq $~(0x00000004), %rax
    andq $~(0x00000008), %rax
    orq  $0x00000022, %rax
    movq %rax, %cr0

    # Set CR4.OSFXSR and CR4.OSXMMEXCPT for SSE instructions.
    movq %cr4, %rax
    orq  $0x00000600, %rax
    movq %rax, %cr4

    fninit

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
pd_tables:
    .skip 16384

.balign 16
stack32:
    .skip 4096
stack32_top:

.balign 16
stack64:
    .skip 16384
stack64_top:

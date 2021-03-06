/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Copyright (C) 2012,2013 - ARM Ltd
 * Author: Marc Zyngier <marc.zyngier@arm.com>
 */

#include <linux/arm-smccc.h>
#include <linux/linkage.h>

#include <asm/alternative.h>
#include <asm/assembler.h>
#include <asm/el2_setup.h>
#include <asm/kvm_arm.h>
#include <asm/kvm_asm.h>
#include <asm/kvm_mmu.h>
#include <asm/pgtable-hwdef.h>
#include <asm/sysreg.h>
#include <asm/virt.h>

	.text
	.pushsection	.hyp.idmap.text, "ax"

	.align	11

SYM_CODE_START(__kvm_hyp_init)
	ventry	__invalid		// Synchronous EL2t
	ventry	__invalid		// IRQ EL2t
	ventry	__invalid		// FIQ EL2t
	ventry	__invalid		// Error EL2t

	ventry	__invalid		// Synchronous EL2h
	ventry	__invalid		// IRQ EL2h
	ventry	__invalid		// FIQ EL2h
	ventry	__invalid		// Error EL2h

	ventry	__do_hyp_init		// Synchronous 64-bit EL1
	ventry	__invalid		// IRQ 64-bit EL1
	ventry	__invalid		// FIQ 64-bit EL1
	ventry	__invalid		// Error 64-bit EL1

	ventry	__invalid		// Synchronous 32-bit EL1
	ventry	__invalid		// IRQ 32-bit EL1
	ventry	__invalid		// FIQ 32-bit EL1
	ventry	__invalid		// Error 32-bit EL1

__invalid:
	b	.

	/*
	 * x0: SMCCC function ID
	 * x1: struct kvm_nvhe_init_params PA
	 */
__do_hyp_init:
	/* Check for a stub HVC call */
	cmp	x0, #HVC_STUB_HCALL_NR
	b.lo	__kvm_handle_stub_hvc

	// We only actively check bits [24:31], and everything
	// else has to be zero, which we check at build time.
#if (KVM_HOST_SMCCC_FUNC(__kvm_hyp_init) & 0xFFFFFFFF00FFFFFF)
#error Unexpected __KVM_HOST_SMCCC_FUNC___kvm_hyp_init value
#endif

	ror	x0, x0, #24
	eor	x0, x0, #((KVM_HOST_SMCCC_FUNC(__kvm_hyp_init) >> 24) & 0xF)
	ror	x0, x0, #4
	eor	x0, x0, #((KVM_HOST_SMCCC_FUNC(__kvm_hyp_init) >> 28) & 0xF)
	cbz	x0, 1f
	mov	x0, #SMCCC_RET_NOT_SUPPORTED
	eret

1:	mov	x0, x1
	mov	x4, lr
	bl	___kvm_hyp_init
	mov	lr, x4

	/* Hello, World! */
	mov	x0, #SMCCC_RET_SUCCESS
	eret
SYM_CODE_END(__kvm_hyp_init)

/*
 * Initialize the hypervisor in EL2.
 *
 * Only uses x0..x3 so as to not clobber callee-saved SMCCC registers
 * and leave x4 for the caller.
 *
 * x0: struct kvm_nvhe_init_params PA
 */
SYM_CODE_START_LOCAL(___kvm_hyp_init)
alternative_if ARM64_KVM_PROTECTED_MODE
	mov_q	x1, HCR_HOST_NVHE_PROTECTED_FLAGS
	msr	hcr_el2, x1
alternative_else_nop_endif

	ldr	x1, [x0, #NVHE_INIT_TPIDR_EL2]
	msr	tpidr_el2, x1

	ldr	x1, [x0, #NVHE_INIT_STACK_HYP_VA]
	mov	sp, x1

	ldr	x1, [x0, #NVHE_INIT_MAIR_EL2]
	msr	mair_el2, x1

	ldr	x1, [x0, #NVHE_INIT_PGD_PA]
	phys_to_ttbr x2, x1
alternative_if ARM64_HAS_CNP
	orr	x2, x2, #TTBR_CNP_BIT
alternative_else_nop_endif
	msr	ttbr0_el2, x2

	/*
	 * Set the PS bits in TCR_EL2.
	 */
	ldr	x1, [x0, #NVHE_INIT_TCR_EL2]
	tcr_compute_pa_size x1, #TCR_EL2_PS_SHIFT, x2, x3
	msr	tcr_el2, x1

	isb

	/* Invalidate the stale TLBs from Bootloader */
	tlbi	alle2
	dsb	sy

	/*
	 * Preserve all the RES1 bits while setting the default flags,
	 * as well as the EE bit on BE. Drop the A flag since the compiler
	 * is allowed to generate unaligned accesses.
	 */
	mov_q	x0, (SCTLR_EL2_RES1 | (SCTLR_ELx_FLAGS & ~SCTLR_ELx_A))
CPU_BE(	orr	x0, x0, #SCTLR_ELx_EE)
alternative_if ARM64_HAS_ADDRESS_AUTH
	mov_q	x1, (SCTLR_ELx_ENIA | SCTLR_ELx_ENIB | \
		     SCTLR_ELx_ENDA | SCTLR_ELx_ENDB)
	orr	x0, x0, x1
alternative_else_nop_endif
	msr	sctlr_el2, x0
	isb

	/* Set the host vector */
	ldr	x0, =__kvm_hyp_host_vector
	kimg_hyp_va x0, x1
	msr	vbar_el2, x0

	ret
SYM_CODE_END(___kvm_hyp_init)

/*
 * PSCI CPU_ON entry point
 *
 * x0: struct kvm_nvhe_init_params PA
 */
SYM_CODE_START(kvm_hyp_cpu_entry)
	mov	x1, #1				// is_cpu_on = true
	b	__kvm_hyp_init_cpu
SYM_CODE_END(kvm_hyp_cpu_entry)

/*
 * PSCI CPU_SUSPEND / SYSTEM_SUSPEND entry point
 *
 * x0: struct kvm_nvhe_init_params PA
 */
SYM_CODE_START(kvm_hyp_cpu_resume)
	mov	x1, #0				// is_cpu_on = false
	b	__kvm_hyp_init_cpu
SYM_CODE_END(kvm_hyp_cpu_resume)

/*
 * Common code for CPU entry points. Initializes EL2 state and
 * installs the hypervisor before handing over to a C handler.
 *
 * x0: struct kvm_nvhe_init_params PA
 * x1: bool is_cpu_on
 */
SYM_CODE_START_LOCAL(__kvm_hyp_init_cpu)
	mov	x28, x0				// Stash arguments
	mov	x29, x1

	/* Check that the core was booted in EL2. */
	mrs	x0, CurrentEL
	cmp	x0, #CurrentEL_EL2
	b.eq	2f

	/* The core booted in EL1. KVM cannot be initialized on it. */
1:	wfe
	wfi
	b	1b

2:	msr	SPsel, #1			// We want to use SP_EL{1,2}

	/* Initialize EL2 CPU state to sane values. */
	init_el2_state nvhe			// Clobbers x0..x2

	/* Enable MMU, set vectors and stack. */
	mov	x0, x28
	bl	___kvm_hyp_init			// Clobbers x0..x3

	/* Leave idmap. */
	mov	x0, x29
	ldr	x1, =kvm_host_psci_cpu_entry
	kimg_hyp_va x1, x2
	br	x1
SYM_CODE_END(__kvm_hyp_init_cpu)

SYM_CODE_START(__kvm_handle_stub_hvc)
	cmp	x0, #HVC_SOFT_RESTART
	b.ne	1f

	/* This is where we're about to jump, staying at EL2 */
	msr	elr_el2, x1
	mov	x0, #(PSR_F_BIT | PSR_I_BIT | PSR_A_BIT | PSR_D_BIT | PSR_MODE_EL2h)
	msr	spsr_el2, x0

	/* Shuffle the arguments, and don't come back */
	mov	x0, x2
	mov	x1, x3
	mov	x2, x4
	b	reset

1:	cmp	x0, #HVC_RESET_VECTORS
	b.ne	1f

	/*
	 * Set the HVC_RESET_VECTORS return code before entering the common
	 * path so that we do not clobber x0-x2 in case we are coming via
	 * HVC_SOFT_RESTART.
	 */
	mov	x0, xzr
reset:
	/* Reset kvm back to the hyp stub. */
	mrs	x5, sctlr_el2
	mov_q	x6, SCTLR_ELx_FLAGS
	bic	x5, x5, x6		// Clear SCTL_M and etc
	pre_disable_mmu_workaround
	msr	sctlr_el2, x5
	isb

alternative_if ARM64_KVM_PROTECTED_MODE
	mov_q	x5, HCR_HOST_NVHE_FLAGS
	msr	hcr_el2, x5
alternative_else_nop_endif

	/* Install stub vectors */
	adr_l	x5, __hyp_stub_vectors
	msr	vbar_el2, x5
	eret

1:	/* Bad stub call */
	mov_q	x0, HVC_STUB_ERR
	eret

SYM_CODE_END(__kvm_handle_stub_hvc)

	.popsection

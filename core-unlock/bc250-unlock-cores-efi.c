// SPDX-License-Identifier: MIT
/*
 * BC-250 pre-boot core unlocker.
 *
 * Adapted and hardened from Hexxeh/bc250-efi-core-unlock commit
 * 3e45131678b111c50e5c285834869ecd3c487a2e. See README.md and the license
 * notices in this directory.
 */
#include <efi.h>

#ifndef NULL
#define NULL ((void *)0)
#endif

#define PCI_CONFIG_ADDRESS 0x0cf8
#define PCI_CONFIG_DATA 0x0cfc
#define BC250_PCI_ID 0x13fe1002U
#define MASK_REG 0x0115A870U
#define LOCKED_MASK 0x00000077U
#define UNLOCKED_MASK 0x000000ffU
#define MSG_WRITE_FF 0x98U
#define Q3_CMD 0x03b10a20U
#define Q3_RSP 0x03b10a80U
#define Q3_ARG 0x03b10a88U
#define EFI_VARIABLE_NON_VOLATILE 0x00000001U
#define EFI_VARIABLE_BOOTSERVICE_ACCESS 0x00000002U
#define EFI_VARIABLE_RUNTIME_ACCESS 0x00000004U
#define EFI_ERROR_STATUS(code) (0x8000000000000000ULL | (EFI_STATUS)(code))

/* Toolkit namespace: 4f6f6f13-1ec2-4f26-a250-bc250c0e77ff. */
static EFI_GUID guard_guid = {
    0x4f6f6f13, 0x1ec2, 0x4f26,
    {0xa2, 0x50, 0xbc, 0x25, 0x0c, 0x0e, 0x77, 0xff}
};
static CHAR16 guard_name[] = L"BC250CoreUnlockAttempt";

void *memcpy(void *destination, const void *source, UINTN size) {
    UINT8 *out = (UINT8 *)destination;
    const UINT8 *in = (const UINT8 *)source;
    while (size-- != 0) {
        *out++ = *in++;
    }
    return destination;
}

void *memset(void *destination, int value, UINTN size) {
    UINT8 *out = (UINT8 *)destination;
    while (size-- != 0) {
        *out++ = (UINT8)value;
    }
    return destination;
}

static inline void out32(UINT16 port, UINT32 value) {
    __asm__ __volatile__("outl %0, %1" : : "a"(value), "Nd"(port));
}

static inline UINT32 in32(UINT16 port) {
    UINT32 value;
    __asm__ __volatile__("inl %1, %0" : "=a"(value) : "Nd"(port));
    return value;
}

static UINT32 pci_read32(UINT32 offset) {
    out32(PCI_CONFIG_ADDRESS, 0x80000000U | (offset & 0xfcU));
    return in32(PCI_CONFIG_DATA);
}

static UINT32 smn_read(UINT32 address) {
    out32(PCI_CONFIG_ADDRESS, 0x800000b8U);
    out32(PCI_CONFIG_DATA, address);
    out32(PCI_CONFIG_ADDRESS, 0x800000bcU);
    return in32(PCI_CONFIG_DATA);
}

static void smn_write(UINT32 address, UINT32 value) {
    out32(PCI_CONFIG_ADDRESS, 0x800000b8U);
    out32(PCI_CONFIG_DATA, address);
    out32(PCI_CONFIG_ADDRESS, 0x800000bcU);
    out32(PCI_CONFIG_DATA, value);
}

static void print(EFI_SYSTEM_TABLE *system_table, CHAR16 *text) {
    system_table->ConOut->OutputString(system_table->ConOut, text);
}

static void print_hex(EFI_SYSTEM_TABLE *system_table, UINT32 value) {
    CHAR16 buffer[11];
    INT32 index;
    buffer[0] = '0';
    buffer[1] = 'x';
    for (index = 7; index >= 0; --index) {
        UINT32 digit = (value >> (index * 4)) & 0x0fU;
        buffer[9 - index] = (CHAR16)(digit < 10 ? '0' + digit : 'A' + digit - 10);
    }
    buffer[10] = 0;
    print(system_table, buffer);
}

static BOOLEAN response_done(UINT32 response) {
    return response == 0x01U || response == 0xffU || response == 0xfeU ||
           response == 0xfdU || response == 0xfcU;
}

static INT32 send_message(EFI_SYSTEM_TABLE *system_table, UINT32 message,
                          UINT32 argument) {
    INT32 timeout = 2500;
    while (!response_done(smn_read(Q3_RSP))) {
        if (timeout-- <= 0) {
            return -1;
        }
        system_table->BootServices->Stall(2000);
    }

    smn_write(Q3_RSP, 0);
    smn_write(Q3_ARG, argument);
    smn_write(Q3_ARG + 4, 0);
    smn_write(Q3_CMD, message);
    timeout = 2500;
    while (1) {
        UINT32 response = smn_read(Q3_RSP);
        if (response_done(response)) {
            return (INT32)response;
        }
        if (timeout-- <= 0) {
            return -2;
        }
        system_table->BootServices->Stall(2000);
    }
}

static EFI_STATUS clear_guard(EFI_SYSTEM_TABLE *system_table) {
    return system_table->RuntimeServices->SetVariable(
        guard_name, &guard_guid, 0, 0, NULL);
}

EFI_STATUS efi_main(EFI_HANDLE image_handle, EFI_SYSTEM_TABLE *system_table) {
    EFI_STATUS status;
    UINT32 attributes = 0;
    UINT32 mask;
    UINTN guard_size = 1;
    UINT8 guard = 0;
    INT32 response;
    (void)image_handle;

    print(system_table, L"BC-250 core unlock: checking hardware and mask\r\n");
    if (pci_read32(0) != BC250_PCI_ID) {
        print(system_table, L"BC-250 core unlock: PCI ID is not 1002:13FE; SMU access refused\r\n");
        return EFI_ERROR_STATUS(EFI_UNSUPPORTED);
    }

    mask = smn_read(MASK_REG);
    if (mask == UNLOCKED_MASK) {
        status = clear_guard(system_table);
        if (status != EFI_SUCCESS && status != EFI_ERROR_STATUS(EFI_NOT_FOUND)) {
            print(system_table, L"BC-250 core unlock: could not clear attempt guard\r\n");
            return EFI_ERROR_STATUS(EFI_DEVICE_ERROR);
        }
        print(system_table, L"BC-250 core unlock: mask is exactly 0x000000FF; returning EFI_ABORTED for next BootOrder entry\r\n");
        return EFI_ERROR_STATUS(EFI_ABORTED);
    }
    if (mask != LOCKED_MASK) {
        print(system_table, L"BC-250 core unlock: unexpected full mask ");
        print_hex(system_table, mask);
        print(system_table, L"; refusing SMU write\r\n");
        return EFI_ERROR_STATUS(EFI_COMPROMISED_DATA);
    }

    status = system_table->RuntimeServices->GetVariable(
        guard_name, &guard_guid, &attributes, &guard_size, &guard);
    if (status == EFI_SUCCESS) {
        print(system_table, L"BC-250 core unlock: prior attempt guard is set; refusing another warm reset\r\n");
        return EFI_ERROR_STATUS(EFI_ALREADY_STARTED);
    }
    if (status != EFI_ERROR_STATUS(EFI_NOT_FOUND)) {
        print(system_table, L"BC-250 core unlock: attempt guard could not be read; refusing SMU write\r\n");
        return EFI_ERROR_STATUS(EFI_DEVICE_ERROR);
    }

    guard = 1;
    status = system_table->RuntimeServices->SetVariable(
        guard_name, &guard_guid,
        EFI_VARIABLE_NON_VOLATILE | EFI_VARIABLE_BOOTSERVICE_ACCESS |
            EFI_VARIABLE_RUNTIME_ACCESS,
        sizeof(guard), &guard);
    if (status != EFI_SUCCESS) {
        print(system_table, L"BC-250 core unlock: could not persist one-attempt guard; refusing SMU write\r\n");
        return EFI_ERROR_STATUS(EFI_WRITE_PROTECTED);
    }

    print(system_table, L"BC-250 core unlock: sending queue 3 message 0x98\r\n");
    response = send_message(system_table, MSG_WRITE_FF, MASK_REG);
    if (response < 0) {
        print(system_table, L"BC-250 core unlock: SMU mailbox timed out; guard retained\r\n");
        return EFI_ERROR_STATUS(EFI_TIMEOUT);
    }
    if (response != 0x01) {
        print(system_table, L"BC-250 core unlock: message 0x98 failed with response ");
        print_hex(system_table, (UINT32)response);
        print(system_table, L"; guard retained\r\n");
        return EFI_ERROR_STATUS(EFI_DEVICE_ERROR);
    }
    mask = smn_read(MASK_REG);
    if (mask != UNLOCKED_MASK) {
        print(system_table, L"BC-250 core unlock: post-write full mask is ");
        print_hex(system_table, mask);
        print(system_table, L", not 0x000000FF; guard retained\r\n");
        return EFI_ERROR_STATUS(EFI_DEVICE_ERROR);
    }

    print(system_table, L"BC-250 core unlock: mask verified; requesting one firmware warm reset\r\n");
    system_table->RuntimeServices->ResetSystem(EfiResetWarm, EFI_SUCCESS, 0, NULL);
    print(system_table, L"BC-250 core unlock: firmware returned from ResetSystem unexpectedly\r\n");
    return EFI_ERROR_STATUS(EFI_DEVICE_ERROR);
}

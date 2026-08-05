#include <PiPei.h>

#include <Library/BaseLib.h>
#include <Library/BaseMemoryLib.h>
#include <Library/HobLib.h>
#include <Library/IoLib.h>
#include <Library/PeiServicesLib.h>
#include <Ppi/Stall.h>

#include "Include/Bc250Mailbox.h"
#include "Include/Bc250PeiResult.h"

#define PCI_CONFIG_ADDRESS  0x0cf8U
#define PCI_CONFIG_DATA     0x0cfcU
#define BC250_CORE_PRESENCE 0x0115a870U
#define BC250_ROOT_PCI_ID    0x13e01022U
#define BC250_GPU_PCI_ID     0x13fe1002U
#define BC250_ROOT_PCI_ADDR  0x80000000U
#define BC250_GPU_PCI_ADDR   0x80010000U

typedef struct {
  CONST EFI_PEI_SERVICES **PeiServices;
  EFI_PEI_STALL_PPI      *StallPpi;
} BC250_PEI_IO_CONTEXT;

STATIC BOOLEAN mProbeAttempted;

STATIC_ASSERT (sizeof (BC250_PEI_RESULT) == 56, "BC250 PEI HOB ABI changed");

STATIC
UINT32
Bc250PciRead32 (
  IN UINT32 Address
  )
{
  IoWrite32 (PCI_CONFIG_ADDRESS, Address);
  return IoRead32 (PCI_CONFIG_DATA);
}

STATIC
UINT32
Bc250SmnRead32 (
  IN VOID   *Context,
  IN UINT32 Address
  )
{
  (VOID)Context;
  IoWrite32 (PCI_CONFIG_ADDRESS, 0x800000b8U);
  IoWrite32 (PCI_CONFIG_DATA, Address);
  IoWrite32 (PCI_CONFIG_ADDRESS, 0x800000bcU);
  return IoRead32 (PCI_CONFIG_DATA);
}

STATIC
BOOLEAN
Bc250SmnWrite32 (
  IN VOID   *Context,
  IN UINT32 Address,
  IN UINT32 Value
  )
{
  (VOID)Context;
  if (!((Address == BC250_Q4_RESPONSE && Value == 0) ||
        (Address == BC250_Q4_ARGUMENT &&
         Value == BC250_DISPATCH_CONFIG_ADDRESS) ||
        (Address == BC250_Q4_COMMAND &&
         Value == BC250_LOCAL_READ_MESSAGE))) {
    return FALSE;
  }

  IoWrite32 (PCI_CONFIG_ADDRESS, 0x800000b8U);
  IoWrite32 (PCI_CONFIG_DATA, Address);
  IoWrite32 (PCI_CONFIG_ADDRESS, 0x800000bcU);
  IoWrite32 (PCI_CONFIG_DATA, Value);
  return TRUE;
}

STATIC
VOID
Bc250IoFence (
  IN VOID *Context
  )
{
  (VOID)Context;
  MemoryFence ();
}

STATIC
BOOLEAN
Bc250Stall (
  IN VOID   *Context,
  IN UINT32 Microseconds
  )
{
  BC250_PEI_IO_CONTEXT *PeiContext;

  PeiContext = Context;
  return (BOOLEAN)!EFI_ERROR (
                    PeiContext->StallPpi->Stall (
                                           PeiContext->PeiServices,
                                           PeiContext->StallPpi,
                                           Microseconds
                                           )
                    );
}

STATIC
BOOLEAN
Bc250PublishResult (
  IN BC250_PEI_RESULT *Result
  )
{
  return (BOOLEAN)(
                     BuildGuidDataHob (
                       &gBc250PeiResultHobGuid,
                       Result,
                       sizeof (*Result)
                       ) != NULL
                     );
}

STATIC
EFI_STATUS
EFIAPI
Bc250SmuServicesNotify (
  IN EFI_PEI_SERVICES          **PeiServices,
  IN EFI_PEI_NOTIFY_DESCRIPTOR *NotifyDescriptor,
  IN VOID                      *Ppi
  )
{
  BC250_MAILBOX_IO Io;
  BC250_PEI_IO_CONTEXT IoContext;
  BC250_PEI_RESULT Result;
  EFI_STATUS Status;

  (VOID)NotifyDescriptor;
  (VOID)Ppi;

  if (mProbeAttempted) {
    return EFI_SUCCESS;
  }

  mProbeAttempted = TRUE;
  ZeroMem (&Result, sizeof (Result));
  Result.Magic = BC250_PEI_RESULT_MAGIC;
  Result.Version = BC250_PEI_RESULT_VERSION;
  Result.Size = sizeof (Result);
  Result.Stage = Bc250PeiStageCallbackEntered;
  Result.RootPciId = Bc250PciRead32 (BC250_ROOT_PCI_ADDR);
  Result.GpuPciId = Bc250PciRead32 (BC250_GPU_PCI_ADDR);
  if (Result.RootPciId != BC250_ROOT_PCI_ID ||
      Result.GpuPciId != BC250_GPU_PCI_ID) {
    Result.Stage = Bc250PeiStagePlatformMismatch;
    return Bc250PublishResult (&Result) ? EFI_SUCCESS : EFI_OUT_OF_RESOURCES;
  }

  IoContext.PeiServices = (CONST EFI_PEI_SERVICES **)PeiServices;
  Status = PeiServicesLocatePpi (
             &gEfiPeiStallPpiGuid,
             0,
             NULL,
             (VOID **)&IoContext.StallPpi
             );
  if (EFI_ERROR (Status)) {
    Result.Stage = Bc250PeiStageStallPpiMissing;
    return Bc250PublishResult (&Result) ? EFI_SUCCESS : EFI_OUT_OF_RESOURCES;
  }

  Io.Context = &IoContext;
  Io.Read32 = Bc250SmnRead32;
  Io.Write32 = Bc250SmnWrite32;
  Io.Fence = Bc250IoFence;
  Io.Stall = Bc250Stall;
  Io.PollMicroseconds = BC250_MAILBOX_POLL_US;
  Io.TimeoutMicroseconds = BC250_MAILBOX_TIMEOUT_US;

  Result.CorePresence = Bc250SmnRead32 (&IoContext, BC250_CORE_PRESENCE);
  Bc250ProbeDispatchGate (&Io, &Result);
  Result.Q4Command = Bc250SmnRead32 (&IoContext, BC250_Q4_COMMAND);
  Result.Q4Response = Bc250SmnRead32 (&IoContext, BC250_Q4_RESPONSE);
  Result.Q4Argument = Bc250SmnRead32 (&IoContext, BC250_Q4_ARGUMENT);
  return Bc250PublishResult (&Result) ? EFI_SUCCESS : EFI_OUT_OF_RESOURCES;
}

STATIC EFI_PEI_NOTIFY_DESCRIPTOR mSmuServicesNotify = {
  EFI_PEI_PPI_DESCRIPTOR_NOTIFY_CALLBACK |
  EFI_PEI_PPI_DESCRIPTOR_TERMINATE_LIST,
  &gBc250SmuServicesPpiGuid,
  Bc250SmuServicesNotify
};

EFI_STATUS
EFIAPI
Bc250EarlyProbePeimEntryPoint (
  IN EFI_PEI_FILE_HANDLE       FileHandle,
  IN CONST EFI_PEI_SERVICES  **PeiServices
  )
{
  (VOID)FileHandle;
  (VOID)PeiServices;
  return PeiServicesNotifyPpi (&mSmuServicesNotify);
}

#ifndef BC250_MAILBOX_H
#define BC250_MAILBOX_H

#include <Base.h>

#include "Bc250PeiResult.h"

#define BC250_Q4_COMMAND   0x03b10a24U
#define BC250_Q4_RESPONSE  0x03b10a84U
#define BC250_Q4_ARGUMENT  0x03b10a8cU

#define BC250_LOCAL_READ_MESSAGE       0x27U
#define BC250_DISPATCH_CONFIG_ADDRESS  0x000075a0U
#define BC250_LOCKED_DISPATCH_CONFIG   0x00000201U

#define BC250_MAILBOX_POLL_US     50U
#define BC250_MAILBOX_TIMEOUT_US  50000U

typedef UINT32 (*BC250_READ32)(VOID *Context, UINT32 Address);
typedef BOOLEAN (*BC250_WRITE32)(VOID *Context, UINT32 Address, UINT32 Value);
typedef VOID (*BC250_FENCE)(VOID *Context);
typedef BOOLEAN (*BC250_STALL)(VOID *Context, UINT32 Microseconds);

typedef struct {
  VOID *Context;
  BC250_READ32 Read32;
  BC250_WRITE32 Write32;
  BC250_FENCE Fence;
  BC250_STALL Stall;
  UINT32 PollMicroseconds;
  UINT32 TimeoutMicroseconds;
} BC250_MAILBOX_IO;

VOID
Bc250ProbeDispatchGate (
  IN CONST BC250_MAILBOX_IO *Io,
  IN OUT BC250_PEI_RESULT   *Result
  );

#endif

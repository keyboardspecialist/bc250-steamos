#include "Include/Bc250Mailbox.h"

typedef enum {
  Bc250WaitComplete,
  Bc250WaitUnknown,
  Bc250WaitStallFailure,
  Bc250WaitTimeout
} BC250_WAIT_RESULT;

STATIC
BOOLEAN
Bc250ResponseIsTerminal (
  IN UINT32 Response
  )
{
  return Response == 0x01U || Response == 0xffU || Response == 0xfeU ||
         Response == 0xfdU || Response == 0xfcU;
}

STATIC
BC250_WAIT_RESULT
Bc250WaitForResponse (
  IN CONST BC250_MAILBOX_IO *Io,
  OUT UINT32                *Response,
  IN OUT UINT32             *PollCount
  )
{
  UINT32 Elapsed;
  UINT32 Value;

  Elapsed = 0;
  while (TRUE) {
    Value = Io->Read32 (Io->Context, BC250_Q4_RESPONSE);
    *PollCount = *PollCount + 1;
    if (Bc250ResponseIsTerminal (Value)) {
      *Response = Value;
      return Bc250WaitComplete;
    }

    if (Value != 0) {
      *Response = Value;
      return Bc250WaitUnknown;
    }

    if (Elapsed >= Io->TimeoutMicroseconds) {
      *Response = Value;
      return Bc250WaitTimeout;
    }

    if (!Io->Stall (Io->Context, Io->PollMicroseconds)) {
      *Response = Value;
      return Bc250WaitStallFailure;
    }
    Elapsed += Io->PollMicroseconds;
  }
}

VOID
Bc250ProbeDispatchGate (
  IN CONST BC250_MAILBOX_IO *Io,
  IN OUT BC250_PEI_RESULT   *Result
  )
{
  BC250_WAIT_RESULT WaitResult;
  UINT32 Response;

  Response = 0;
  WaitResult = Bc250WaitForResponse (Io, &Response, &Result->PollCount);
  Result->InitialResponse = Response;
  if (WaitResult == Bc250WaitTimeout) {
    Result->Stage = Bc250PeiStagePreflightTimeout;
    return;
  }

  if (WaitResult == Bc250WaitUnknown) {
    Result->Stage = Bc250PeiStagePreflightUnknownResponse;
    return;
  }

  if (WaitResult == Bc250WaitStallFailure) {
    Result->Stage = Bc250PeiStagePreflightStallFailure;
    return;
  }

  if (!Io->Write32 (Io->Context, BC250_Q4_RESPONSE, 0) ||
      !Io->Write32 (Io->Context, BC250_Q4_ARGUMENT,
                    BC250_DISPATCH_CONFIG_ADDRESS)) {
    Result->Stage = Bc250PeiStageWriteRefused;
    return;
  }
  Io->Fence (Io->Context);
  if (!Io->Write32 (Io->Context, BC250_Q4_COMMAND,
                    BC250_LOCAL_READ_MESSAGE)) {
    Result->Stage = Bc250PeiStageWriteRefused;
    return;
  }

  Response = 0;
  WaitResult = Bc250WaitForResponse (Io, &Response, &Result->PollCount);
  Result->Response = Response;
  if (WaitResult == Bc250WaitTimeout) {
    Result->Stage = Bc250PeiStageCommandTimeout;
    return;
  }

  if (WaitResult == Bc250WaitUnknown) {
    Result->Stage = Bc250PeiStageCommandUnknownResponse;
    return;
  }

  if (WaitResult == Bc250WaitStallFailure) {
    Result->Stage = Bc250PeiStageCommandStallFailure;
    return;
  }

  if (Response != 0x01U) {
    Result->Stage = Bc250PeiStageCommandRejected;
    return;
  }

  Result->Argument = Io->Read32 (Io->Context, BC250_Q4_ARGUMENT);
  if (Result->Argument != BC250_LOCKED_DISPATCH_CONFIG) {
    Result->Stage = Bc250PeiStageValueMismatch;
    return;
  }

  Result->Flags |= BC250_PEI_FLAG_GATE_OPEN;
  Result->Stage = Bc250PeiStageGateOpen;
}

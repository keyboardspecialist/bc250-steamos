#include "Bc250Mailbox.h"

#define CHECK(Expression) do { if (!(Expression)) { return __LINE__; } } while (0)

typedef struct {
  UINT32 Responses[8];
  UINT32 ResponseCount;
  UINT32 ResponseIndex;
  UINT32 ReturnedArgument;
  struct {
    UINT32 Address;
    UINT32 Value;
  } Writes[8];
  UINT32 WriteCount;
  UINT32 StallCount;
  UINT32 FenceCount;
  BOOLEAN FailStall;
  BOOLEAN RefuseWrite;
} FAKE_IO;

static UINT32
FakeRead32 (VOID *Context, UINT32 Address)
{
  FAKE_IO *Io;

  Io = Context;
  if (Address == BC250_Q4_ARGUMENT) {
    return Io->ReturnedArgument;
  }

  if (Address != BC250_Q4_RESPONSE) {
    return 0xdeadbeefU;
  }
  if (Io->ResponseIndex < Io->ResponseCount) {
    return Io->Responses[Io->ResponseIndex++];
  }

  return Io->Responses[Io->ResponseCount - 1];
}

static BOOLEAN
FakeWrite32 (VOID *Context, UINT32 Address, UINT32 Value)
{
  FAKE_IO *Io;

  Io = Context;
  if (Io->RefuseWrite) {
    return FALSE;
  }
  if (Io->WriteCount >= 8) {
    return FALSE;
  }
  Io->Writes[Io->WriteCount].Address = Address;
  Io->Writes[Io->WriteCount].Value = Value;
  Io->WriteCount++;
  return TRUE;
}

static VOID
FakeFence (VOID *Context)
{
  FAKE_IO *Io;

  Io = Context;
  Io->FenceCount++;
}

static BOOLEAN
FakeStall (VOID *Context, UINT32 Microseconds)
{
  FAKE_IO *Io;

  Io = Context;
  if (Microseconds == 1) {
    Io->StallCount++;
  }
  return (BOOLEAN)!Io->FailStall;
}

static BC250_MAILBOX_IO
Mailbox (FAKE_IO *Fake)
{
  BC250_MAILBOX_IO Io;

  Io.Context = Fake;
  Io.Read32 = FakeRead32;
  Io.Write32 = FakeWrite32;
  Io.Fence = FakeFence;
  Io.Stall = FakeStall;
  Io.PollMicroseconds = 1;
  Io.TimeoutMicroseconds = 2;
  return Io;
}

static BC250_PEI_RESULT
Result (void)
{
  BC250_PEI_RESULT Result;

  Result = (BC250_PEI_RESULT){ 0 };
  return Result;
}

static int
TestGateOpen (void)
{
  FAKE_IO Fake = {
    .Responses = { 0x01, 0x00, 0x01 },
    .ResponseCount = 3,
    .ReturnedArgument = BC250_LOCKED_DISPATCH_CONFIG
  };
  BC250_MAILBOX_IO Io = Mailbox (&Fake);
  BC250_PEI_RESULT Probe = Result ();

  Bc250ProbeDispatchGate (&Io, &Probe);

  CHECK (Probe.Stage == Bc250PeiStageGateOpen);
  CHECK (Probe.Flags == BC250_PEI_FLAG_GATE_OPEN);
  CHECK (Probe.InitialResponse == 0x01);
  CHECK (Probe.Response == 0x01);
  CHECK (Probe.Argument == BC250_LOCKED_DISPATCH_CONFIG);
  CHECK (Fake.WriteCount == 3);
  CHECK (Fake.Writes[0].Address == BC250_Q4_RESPONSE);
  CHECK (Fake.Writes[0].Value == 0);
  CHECK (Fake.Writes[1].Address == BC250_Q4_ARGUMENT);
  CHECK (Fake.Writes[1].Value == BC250_DISPATCH_CONFIG_ADDRESS);
  CHECK (Fake.Writes[2].Address == BC250_Q4_COMMAND);
  CHECK (Fake.Writes[2].Value == BC250_LOCAL_READ_MESSAGE);
  CHECK (Fake.FenceCount == 1);
  CHECK (Fake.StallCount == 1);
  return 0;
}

static int
TestGateClosed (void)
{
  FAKE_IO Fake = {
    .Responses = { 0x01, 0xfd },
    .ResponseCount = 2
  };
  BC250_MAILBOX_IO Io = Mailbox (&Fake);
  BC250_PEI_RESULT Probe = Result ();

  Bc250ProbeDispatchGate (&Io, &Probe);

  CHECK (Probe.Stage == Bc250PeiStageCommandRejected);
  CHECK (Probe.Response == 0xfd);
  CHECK (Probe.Flags == 0);
  CHECK (Fake.WriteCount == 3);
  return 0;
}

static int
TestUnknownPreflightResponseDoesNotWrite (void)
{
  FAKE_IO Fake = {
    .Responses = { 0x42 },
    .ResponseCount = 1
  };
  BC250_MAILBOX_IO Io = Mailbox (&Fake);
  BC250_PEI_RESULT Probe = Result ();

  Bc250ProbeDispatchGate (&Io, &Probe);

  CHECK (Probe.Stage == Bc250PeiStagePreflightUnknownResponse);
  CHECK (Probe.InitialResponse == 0x42);
  CHECK (Fake.WriteCount == 0);
  return 0;
}

static int
TestCommandTimeoutDoesNotRetry (void)
{
  FAKE_IO Fake = {
    .Responses = { 0x01, 0x00, 0x00, 0x00 },
    .ResponseCount = 4
  };
  BC250_MAILBOX_IO Io = Mailbox (&Fake);
  BC250_PEI_RESULT Probe = Result ();

  Bc250ProbeDispatchGate (&Io, &Probe);

  CHECK (Probe.Stage == Bc250PeiStageCommandTimeout);
  CHECK (Fake.WriteCount == 3);
  CHECK (Fake.StallCount == 2);
  return 0;
}

static int
TestPreflightTimeoutDoesNotWrite (void)
{
  FAKE_IO Fake = {
    .Responses = { 0x00, 0x00, 0x00 },
    .ResponseCount = 3
  };
  BC250_MAILBOX_IO Io = Mailbox (&Fake);
  BC250_PEI_RESULT Probe = Result ();

  Bc250ProbeDispatchGate (&Io, &Probe);

  CHECK (Probe.Stage == Bc250PeiStagePreflightTimeout);
  CHECK (Fake.WriteCount == 0);
  CHECK (Fake.StallCount == 2);
  return 0;
}

static int
TestUnknownCommandResponseDoesNotRetry (void)
{
  FAKE_IO Fake = {
    .Responses = { 0x01, 0x42 },
    .ResponseCount = 2
  };
  BC250_MAILBOX_IO Io = Mailbox (&Fake);
  BC250_PEI_RESULT Probe = Result ();

  Bc250ProbeDispatchGate (&Io, &Probe);

  CHECK (Probe.Stage == Bc250PeiStageCommandUnknownResponse);
  CHECK (Probe.Response == 0x42);
  CHECK (Fake.WriteCount == 3);
  return 0;
}

static int
TestStallFailureStopsPolling (void)
{
  FAKE_IO Fake = {
    .Responses = { 0x00 },
    .ResponseCount = 1,
    .FailStall = TRUE
  };
  BC250_MAILBOX_IO Io = Mailbox (&Fake);
  BC250_PEI_RESULT Probe = Result ();

  Bc250ProbeDispatchGate (&Io, &Probe);

  CHECK (Probe.Stage == Bc250PeiStagePreflightStallFailure);
  CHECK (Fake.StallCount == 1);
  CHECK (Fake.WriteCount == 0);
  return 0;
}

static int
TestRefusedWriteStopsBeforeCommand (void)
{
  FAKE_IO Fake = {
    .Responses = { 0x01 },
    .ResponseCount = 1,
    .RefuseWrite = TRUE
  };
  BC250_MAILBOX_IO Io = Mailbox (&Fake);
  BC250_PEI_RESULT Probe = Result ();

  Bc250ProbeDispatchGate (&Io, &Probe);

  CHECK (Probe.Stage == Bc250PeiStageWriteRefused);
  CHECK (Fake.WriteCount == 0);
  CHECK (Fake.FenceCount == 0);
  return 0;
}

static int
TestAllRejectionResponses (void)
{
  UINT32 Responses[] = { 0xfc, 0xfe, 0xff };
  UINT32 Index;

  for (Index = 0; Index < sizeof (Responses) / sizeof (Responses[0]); Index++) {
    FAKE_IO Fake = {
      .Responses = { 0x01, 0x00 },
      .ResponseCount = 2
    };
    BC250_MAILBOX_IO Io = Mailbox (&Fake);
    BC250_PEI_RESULT Probe = Result ();

    Fake.Responses[1] = Responses[Index];
    Bc250ProbeDispatchGate (&Io, &Probe);
    CHECK (Probe.Stage == Bc250PeiStageCommandRejected);
    CHECK (Probe.Response == Responses[Index]);
    CHECK (Fake.WriteCount == 3);
  }

  return 0;
}

static int
TestUnexpectedValueIsNotAccepted (void)
{
  FAKE_IO Fake = {
    .Responses = { 0x01, 0x01 },
    .ResponseCount = 2,
    .ReturnedArgument = 0x00000001
  };
  BC250_MAILBOX_IO Io = Mailbox (&Fake);
  BC250_PEI_RESULT Probe = Result ();

  Bc250ProbeDispatchGate (&Io, &Probe);

  CHECK (Probe.Stage == Bc250PeiStageValueMismatch);
  CHECK (Probe.Flags == 0);
  CHECK (Probe.Argument == 0x00000001);
  return 0;
}

int
main (void)
{
  int Result;

  Result = TestGateOpen ();
  if (Result != 0) {
    return Result;
  }
  Result = TestGateClosed ();
  if (Result != 0) {
    return Result;
  }
  Result = TestUnknownPreflightResponseDoesNotWrite ();
  if (Result != 0) {
    return Result;
  }
  Result = TestCommandTimeoutDoesNotRetry ();
  if (Result != 0) {
    return Result;
  }
  Result = TestPreflightTimeoutDoesNotWrite ();
  if (Result != 0) {
    return Result;
  }
  Result = TestUnknownCommandResponseDoesNotRetry ();
  if (Result != 0) {
    return Result;
  }
  Result = TestStallFailureStopsPolling ();
  if (Result != 0) {
    return Result;
  }
  Result = TestRefusedWriteStopsBeforeCommand ();
  if (Result != 0) {
    return Result;
  }
  Result = TestAllRejectionResponses ();
  if (Result != 0) {
    return Result;
  }
  Result = TestUnexpectedValueIsNotAccepted ();
  if (Result != 0) {
    return Result;
  }
  return 0;
}

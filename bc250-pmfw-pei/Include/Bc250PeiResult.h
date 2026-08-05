#ifndef BC250_PEI_RESULT_H
#define BC250_PEI_RESULT_H

#include <Base.h>

#define BC250_PEI_RESULT_MAGIC  SIGNATURE_32('B', 'P', 'E', 'I')
#define BC250_PEI_RESULT_VERSION  1U

#define BC250_PEI_FLAG_GATE_OPEN  BIT0

typedef enum {
  Bc250PeiStageNotRun = 0,
  Bc250PeiStageCallbackEntered = 1,
  Bc250PeiStagePlatformMismatch = 2,
  Bc250PeiStageStallPpiMissing = 3,
  Bc250PeiStagePreflightTimeout = 4,
  Bc250PeiStagePreflightUnknownResponse = 5,
  Bc250PeiStagePreflightStallFailure = 6,
  Bc250PeiStageWriteRefused = 7,
  Bc250PeiStageCommandTimeout = 8,
  Bc250PeiStageCommandUnknownResponse = 9,
  Bc250PeiStageCommandStallFailure = 10,
  Bc250PeiStageCommandRejected = 11,
  Bc250PeiStageValueMismatch = 12,
  Bc250PeiStageGateOpen = 13
} BC250_PEI_STAGE;

typedef struct {
  UINT32 Magic;
  UINT16 Version;
  UINT16 Size;
  UINT32 Stage;
  UINT32 Flags;
  UINT32 InitialResponse;
  UINT32 Response;
  UINT32 Argument;
  UINT32 PollCount;
  UINT32 Q4Command;
  UINT32 Q4Response;
  UINT32 Q4Argument;
  UINT32 CorePresence;
  UINT32 RootPciId;
  UINT32 GpuPciId;
} BC250_PEI_RESULT;

#endif

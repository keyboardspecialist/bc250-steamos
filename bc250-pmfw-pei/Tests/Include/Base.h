#ifndef TEST_BASE_H
#define TEST_BASE_H

#define IN
#define OUT
#define STATIC static
#define CONST const
#define VOID void
#define TRUE 1
#define FALSE 0
#define BIT0 1U
#define SIGNATURE_32(A, B, C, D) \
  ((UINT32)(A) | ((UINT32)(B) << 8) | ((UINT32)(C) << 16) | \
   ((UINT32)(D) << 24))

typedef unsigned char BOOLEAN;
typedef unsigned short UINT16;
typedef unsigned int UINT32;

#endif

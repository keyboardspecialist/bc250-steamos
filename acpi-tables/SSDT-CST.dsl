// BC-250 C-states for factory 6c/12t and unlocked 8c/16t topologies.
DefinitionBlock ("", "SSDT", 2, "BC250", "P_CST3", 0x00000002)
{
    External (\_PR, DeviceObj)
    External (\_PR.P000, ProcessorObj)
    External (\_PR.P001, ProcessorObj)
    External (\_PR.P002, ProcessorObj)
    External (\_PR.P003, ProcessorObj)
    External (\_PR.P004, ProcessorObj)
    External (\_PR.P005, ProcessorObj)
    External (\_PR.P006, ProcessorObj)
    External (\_PR.P007, ProcessorObj)
    External (\_PR.P008, ProcessorObj)
    External (\_PR.P009, ProcessorObj)
    External (\_PR.P00A, ProcessorObj)
    External (\_PR.P00B, ProcessorObj)
    External (\_PR.P00C, ProcessorObj)
    External (\_PR.P00D, ProcessorObj)
    External (\_PR.P00E, ProcessorObj)
    External (\_PR.P00F, ProcessorObj)

    Method (PCST, 0, NotSerialized)
    {
        Return (Package ()
        {
            0x03,
            Package ()
            {
                ResourceTemplate ()
                {
                    Register (FFixedHW, 0x02, 0x02, 0x0000000000000000)
                },
                0x01,
                0x0001,
                0x00000000
            },
            Package ()
            {
                ResourceTemplate ()
                {
                    Register (SystemIO, 0x08, 0x00, 0x0000000000000414, 0x01)
                },
                0x02,
                0x015E,
                0x00000000
            },
            Package ()
            {
                ResourceTemplate ()
                {
                    Register (SystemIO, 0x08, 0x00, 0x0000000000000415, 0x01)
                },
                0x03,
                0x0190,
                0x00000000
            }
        })
    }

    Scope (\_PR.P000) { Method (_CST, 0, NotSerialized) { Return (PCST ()) } }
    Scope (\_PR.P001) { Method (_CST, 0, NotSerialized) { Return (PCST ()) } }
    Scope (\_PR.P002) { Method (_CST, 0, NotSerialized) { Return (PCST ()) } }
    Scope (\_PR.P003) { Method (_CST, 0, NotSerialized) { Return (PCST ()) } }
    Scope (\_PR.P004) { Method (_CST, 0, NotSerialized) { Return (PCST ()) } }
    Scope (\_PR.P005) { Method (_CST, 0, NotSerialized) { Return (PCST ()) } }
    Scope (\_PR.P006) { Method (_CST, 0, NotSerialized) { Return (PCST ()) } }
    Scope (\_PR.P007) { Method (_CST, 0, NotSerialized) { Return (PCST ()) } }
    Scope (\_PR.P008) { Method (_CST, 0, NotSerialized) { Return (PCST ()) } }
    Scope (\_PR.P009) { Method (_CST, 0, NotSerialized) { Return (PCST ()) } }
    Scope (\_PR.P00A) { Method (_CST, 0, NotSerialized) { Return (PCST ()) } }
    Scope (\_PR.P00B) { Method (_CST, 0, NotSerialized) { Return (PCST ()) } }

    Scope (\_PR)
    {
        Alias (\_PR.P000, C000)
        Alias (\_PR.P001, C001)
        Alias (\_PR.P002, C002)
        Alias (\_PR.P003, C003)
        Alias (\_PR.P004, C004)
        Alias (\_PR.P005, C005)
        Alias (\_PR.P006, C006)
        Alias (\_PR.P007, C007)
        Alias (\_PR.P008, C008)
        Alias (\_PR.P009, C009)
        Alias (\_PR.P00A, C00A)
        Alias (\_PR.P00B, C00B)
    }

    If (CondRefOf (\_PR.P00C))
    {
        Scope (\_PR.P00C) { Method (_CST, 0, NotSerialized) { Return (PCST ()) } }
        Scope (\_PR) { Alias (\_PR.P00C, C00C) }
    }
    If (CondRefOf (\_PR.P00D))
    {
        Scope (\_PR.P00D) { Method (_CST, 0, NotSerialized) { Return (PCST ()) } }
        Scope (\_PR) { Alias (\_PR.P00D, C00D) }
    }
    If (CondRefOf (\_PR.P00E))
    {
        Scope (\_PR.P00E) { Method (_CST, 0, NotSerialized) { Return (PCST ()) } }
        Scope (\_PR) { Alias (\_PR.P00E, C00E) }
    }
    If (CondRefOf (\_PR.P00F))
    {
        Scope (\_PR.P00F) { Method (_CST, 0, NotSerialized) { Return (PCST ()) } }
        Scope (\_PR) { Alias (\_PR.P00F, C00F) }
    }
}

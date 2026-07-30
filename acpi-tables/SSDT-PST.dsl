// BC-250 P-states for factory 6c/12t and unlocked 8c/16t topologies.
DefinitionBlock ("", "SSDT", 2, "BC250", "PSTATES", 0x00000002)
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

    Name (PPCT, Package ()
    {
        ResourceTemplate () { Register (FFixedHW, 64, 0, 0x00000000C0010062) },
        ResourceTemplate () { Register (FFixedHW, 64, 0, 0x0000000000000000) }
    })

    Name (PPSS, Package ()
    {
        Package () { 3200, 0, 1000, 1000, 0, 0 },
        Package () { 2550, 0, 1000, 1000, 1, 1 },
        Package () { 2325, 0, 1000, 1000, 2, 2 },
        Package () { 1960, 0, 1000, 1000, 3, 3 },
        Package () { 1820, 0, 1000, 1000, 4, 4 },
        Package () { 1600, 0, 1000, 1000, 5, 5 },
        Package () { 1271, 0, 1000, 1000, 6, 6 },
        Package () {  800, 0, 1000, 1000, 7, 7 }
    })

    Name (PPSD, Package ()
    {
        Package () { 0x05, 0x00, 0x00000001, 0x000000FE, 0x00000002 }
    })

    Scope (\_PR)
    {
        Scope (P000) { Method (_PCT, 0, NotSerialized) { Return (PPCT) } Method (_PSS, 0, NotSerialized) { Return (PPSS) } Method (_PSD, 0, NotSerialized) { Return (PPSD) } }
        Scope (P001) { Method (_PCT, 0, NotSerialized) { Return (PPCT) } Method (_PSS, 0, NotSerialized) { Return (PPSS) } Method (_PSD, 0, NotSerialized) { Return (PPSD) } }
        Scope (P002) { Method (_PCT, 0, NotSerialized) { Return (PPCT) } Method (_PSS, 0, NotSerialized) { Return (PPSS) } Method (_PSD, 0, NotSerialized) { Return (PPSD) } }
        Scope (P003) { Method (_PCT, 0, NotSerialized) { Return (PPCT) } Method (_PSS, 0, NotSerialized) { Return (PPSS) } Method (_PSD, 0, NotSerialized) { Return (PPSD) } }
        Scope (P004) { Method (_PCT, 0, NotSerialized) { Return (PPCT) } Method (_PSS, 0, NotSerialized) { Return (PPSS) } Method (_PSD, 0, NotSerialized) { Return (PPSD) } }
        Scope (P005) { Method (_PCT, 0, NotSerialized) { Return (PPCT) } Method (_PSS, 0, NotSerialized) { Return (PPSS) } Method (_PSD, 0, NotSerialized) { Return (PPSD) } }
        Scope (P006) { Method (_PCT, 0, NotSerialized) { Return (PPCT) } Method (_PSS, 0, NotSerialized) { Return (PPSS) } Method (_PSD, 0, NotSerialized) { Return (PPSD) } }
        Scope (P007) { Method (_PCT, 0, NotSerialized) { Return (PPCT) } Method (_PSS, 0, NotSerialized) { Return (PPSS) } Method (_PSD, 0, NotSerialized) { Return (PPSD) } }
        Scope (P008) { Method (_PCT, 0, NotSerialized) { Return (PPCT) } Method (_PSS, 0, NotSerialized) { Return (PPSS) } Method (_PSD, 0, NotSerialized) { Return (PPSD) } }
        Scope (P009) { Method (_PCT, 0, NotSerialized) { Return (PPCT) } Method (_PSS, 0, NotSerialized) { Return (PPSS) } Method (_PSD, 0, NotSerialized) { Return (PPSD) } }
        Scope (P00A) { Method (_PCT, 0, NotSerialized) { Return (PPCT) } Method (_PSS, 0, NotSerialized) { Return (PPSS) } Method (_PSD, 0, NotSerialized) { Return (PPSD) } }
        Scope (P00B) { Method (_PCT, 0, NotSerialized) { Return (PPCT) } Method (_PSS, 0, NotSerialized) { Return (PPSS) } Method (_PSD, 0, NotSerialized) { Return (PPSD) } }
    }

    If (CondRefOf (\_PR.P00C))
    {
        Scope (\_PR.P00C) { Method (_PCT, 0, NotSerialized) { Return (PPCT) } Method (_PSS, 0, NotSerialized) { Return (PPSS) } Method (_PSD, 0, NotSerialized) { Return (PPSD) } }
    }
    If (CondRefOf (\_PR.P00D))
    {
        Scope (\_PR.P00D) { Method (_PCT, 0, NotSerialized) { Return (PPCT) } Method (_PSS, 0, NotSerialized) { Return (PPSS) } Method (_PSD, 0, NotSerialized) { Return (PPSD) } }
    }
    If (CondRefOf (\_PR.P00E))
    {
        Scope (\_PR.P00E) { Method (_PCT, 0, NotSerialized) { Return (PPCT) } Method (_PSS, 0, NotSerialized) { Return (PPSS) } Method (_PSD, 0, NotSerialized) { Return (PPSD) } }
    }
    If (CondRefOf (\_PR.P00F))
    {
        Scope (\_PR.P00F) { Method (_PCT, 0, NotSerialized) { Return (PPCT) } Method (_PSS, 0, NotSerialized) { Return (PPSS) } Method (_PSD, 0, NotSerialized) { Return (PPSD) } }
    }
}

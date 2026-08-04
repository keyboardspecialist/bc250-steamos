// Export decompilation and cross-reference evidence for Robin 3 metrics paths.
// @category BC250

import java.io.File;
import java.io.PrintWriter;
import java.util.ArrayDeque;
import java.util.HashSet;
import java.util.Set;

import ghidra.app.cmd.disassemble.DisassembleCommand;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.address.AddressSet;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import ghidra.program.model.listing.FlowOverride;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import ghidra.program.model.mem.Memory;
import ghidra.program.model.symbol.Reference;

public class ExportSmuAnalysis extends GhidraScript {
    private static final long[] TARGETS = {
        0x0fa8, 0x0ffc,
        0x1b998, 0x1b9b4, 0x1b9f4, 0x1ba10, 0x1ba5c,
        0x1b9d0, 0x27528, 0x276b8, 0x276cc, 0x276dc,
        0x286f8, 0x398d4, 0x398e8, 0x398fc, 0x39910, 0x3a850
    };

    private Function ensureFunction(long offset) throws Exception {
        Address address = toAddr(offset);
        FunctionManager functions = currentProgram.getFunctionManager();
        Function function = functions.getFunctionAt(address);
        if (function != null) {
            return function;
        }

        if (currentProgram.getListing().getInstructionAt(address) == null) {
            clearListing(address, address.add(3));
        }
        DisassembleCommand command = new DisassembleCommand(address, null, true);
        boolean disassembled = command.applyTo(currentProgram, monitor);
        println(String.format("0x%x disassembled=%s status=%s instruction=%s",
            offset, disassembled, command.getStatusMsg(),
            currentProgram.getListing().getInstructionAt(address)));
        function = createFunction(address, null);
        if (function == null) {
            function = functions.getFunctionContaining(address);
        }
        println(String.format("0x%x function=%s", offset, function));
        return function;
    }

    private void dumpWords(PrintWriter out, long start, int byteCount) throws Exception {
        Memory memory = currentProgram.getMemory();
        out.printf("\n== words 0x%x..0x%x ==%n", start, start + byteCount - 1);
        for (int offset = 0; offset < byteCount; offset += 16) {
            out.printf("%08x:", start + offset);
            for (int word = 0; word < 4 && offset + word * 4 < byteCount; word++) {
                out.printf(" %08x", memory.getInt(toAddr(start + offset + word * 4)));
            }
            out.println();
        }
    }

    private void dumpFunction(PrintWriter out, DecompInterface decompiler,
            Function function) throws Exception {
        out.printf("\n============================================================%n");
        out.printf("FUNCTION %s @ %s body=%s%n", function.getName(),
            function.getEntryPoint(), function.getBody());

        out.println("CALLERS:");
        for (Function caller : function.getCallingFunctions(monitor)) {
            out.printf("  %s @ %s%n", caller.getName(), caller.getEntryPoint());
        }
        out.println("CALLEES:");
        for (Function callee : function.getCalledFunctions(monitor)) {
            out.printf("  %s @ %s%n", callee.getName(), callee.getEntryPoint());
        }
        out.println("REFERENCES TO ENTRY:");
        for (Reference reference : getReferencesTo(function.getEntryPoint())) {
            out.printf("  %s type=%s source=%s%n", reference.getFromAddress(),
                reference.getReferenceType(), reference.getSource());
        }
        out.println("INSTRUCTIONS:");
        InstructionIterator instructions = currentProgram.getListing()
            .getInstructions(function.getBody(), true);
        while (instructions.hasNext()) {
            Instruction instruction = instructions.next();
            out.printf("  %s  %-28s flows=", instruction.getAddress(), instruction);
            for (Address flow : instruction.getFlows()) {
                out.printf("%s ", flow);
            }
            out.println();
        }

        DecompileResults result = decompiler.decompileFunction(function, 120, monitor);
        if (!result.decompileCompleted()) {
            out.printf("DECOMPILE FAILED: %s%n", result.getErrorMessage());
            return;
        }
        out.println("DECOMPILATION:");
        out.println(result.getDecompiledFunction().getC());
    }

    @Override
    protected void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length != 1) {
            throw new IllegalArgumentException("usage: ExportSmuAnalysis.java OUTPUT");
        }

        Function readMailboxArgument = ensureFunction(0xffc);
        readMailboxArgument.setNoReturn(false);
        Function floatingPointHelper = ensureFunction(0x3a9b8);
        floatingPointHelper.setNoReturn(false);

        // A raw import can initially classify the argument getter as non-returning,
        // which truncates every mailbox handler at its first call. Recreate those
        // functions after correcting that property so flow analysis sees each body.
        long[] mailboxHandlers = { 0x1b998, 0x1b9b4, 0x1b9f4, 0x1ba10, 0x1ba5c };
        for (long handler : mailboxHandlers) {
            currentProgram.getFunctionManager().removeFunction(toAddr(handler));
        }
        for (long target : TARGETS) {
            ensureFunction(target);
        }
        new DisassembleCommand(toAddr(0x27703), null, true)
            .applyTo(currentProgram, monitor);
        long[][] fixedBodies = {
            { 0x1b998, 0x1b9b3 },
            { 0x1b9b4, 0x1b9cf },
            { 0x1b9f4, 0x1ba0f },
            { 0x1ba10, 0x1ba2b },
            { 0x1ba5c, 0x1bafb },
            { 0x276dc, 0x27863 },
        };
        for (long[] body : fixedBodies) {
            Function function = currentProgram.getFunctionManager()
                .getFunctionAt(toAddr(body[0]));
            function.setBody(new AddressSet(toAddr(body[0]), toAddr(body[1])));
        }
        analyzeAll(currentProgram);
        readMailboxArgument.setNoReturn(false);
        floatingPointHelper.setNoReturn(false);
        for (long[] body : fixedBodies) {
            InstructionIterator instructions = currentProgram.getListing().getInstructions(
                new AddressSet(toAddr(body[0]), toAddr(body[1])), true);
            while (instructions.hasNext()) {
                Instruction instruction = instructions.next();
                if (instruction.getFlowOverride() != FlowOverride.NONE) {
                    instruction.setFlowOverride(FlowOverride.NONE);
                }
            }
        }

        DecompInterface decompiler = new DecompInterface();
        decompiler.openProgram(currentProgram);

        try (PrintWriter out = new PrintWriter(new File(args[0]))) {
            out.printf("Program: %s%n", currentProgram.getName());
            out.printf("Language: %s%n", currentProgram.getLanguageID());

            // Queue descriptors, shared dispatch entries, and table 3 descriptor.
            dumpWords(out, 0x7000, 0x180);
            dumpWords(out, 0x7060, 0x50);
            dumpWords(out, 0x7460, 0x430);
            dumpWords(out, 0xcaa0, 0x60);

            ArrayDeque<Function> pending = new ArrayDeque<>();
            Set<Address> seen = new HashSet<>();
            for (long target : TARGETS) {
                Function function = currentProgram.getFunctionManager()
                    .getFunctionContaining(toAddr(target));
                if (function != null) {
                    pending.add(function);
                }
            }

            // Include direct helpers because handler semantics are often split across
            // a small mailbox wrapper and one DMA/table callback helper.
            int targetAndHelperCount = pending.size();
            while (!pending.isEmpty() && seen.size() < targetAndHelperCount + 32) {
                Function function = pending.removeFirst();
                if (!seen.add(function.getEntryPoint())) {
                    continue;
                }
                dumpFunction(out, decompiler, function);
                for (Function callee : function.getCalledFunctions(monitor)) {
                    if (!seen.contains(callee.getEntryPoint())) {
                        pending.addLast(callee);
                    }
                }
            }
        } finally {
            decompiler.dispose();
        }
    }
}

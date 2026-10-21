"""Fixed public CLI contracts; no caller-provided commands or paths."""

CLI_SECTIONS = (
    ("menu", "Toolkit menu", "All toolkit sections", "maintenance"),
    ("status", "System status", "Read-only toolkit status", "read-only"),
    ("setup", "Guided setup", "Canonical setup order and reboot checkpoints", "maintenance"),
    ("toolkit-update", "Toolkit update", "Review release notes and update the toolkit checkout, not the UI binary", "maintenance"),
    ("core", "Core system", "Storage, RAM allocation, swap and update protection", "maintenance"),
    ("graphics", "Complete graphics stack", "AMDGPU builds, DirectMesh, upscalers, codecs and advanced boot options", "maintenance"),
    ("devices", "Devices and connectivity", "Audio, CEC, fan control and wireless integrations", "maintenance"),
    ("maintenance", "Recovery and maintenance", "Update protection, recovery, build cleanup and removal", "maintenance"),
    ("amdgpu-boot", "AMDGPU boot policies", "Mutually exclusive scheduler and experimental KFD policies", "advanced"),
    ("drivers", "Driver maintenance", "AMDGPU, wireless and fan driver workflows", "maintenance"),
    ("unlocks", "Hardware unlocks", "Guarded CPU-core and GPU compute-unit workflows", "advanced"),
    ("storage-updates", "Storage and protection", "Persistent storage and update protection", "maintenance"),
    ("interfaces", "Control interfaces", "Install or update Decky, Plasma, Trainer and CoolerControl", "maintenance"),
    ("power", "Power and GPU", "Power, GPU and CPU tuning", "advanced"),
    ("ram", "Memory split", "UMA and TTM memory configuration", "advanced"),
    ("swap", "Swap", "Swap configuration", "advanced"),
    ("compute", "Compute units", "GPU compute-unit configuration", "advanced"),
    ("cpu-unlock", "Eight-core unlock", "CPU unlock and metrics maintenance", "advanced"),
    ("cec", "HDMI CEC", "TV and receiver controls", "maintenance"),
    ("storage", "Storage", "Persistent storage maintenance", "maintenance"),
    ("persistence", "Update persistence", "Update recovery and persistence", "maintenance"),
    ("wifi-backend", "Wi-Fi backend", "Wireless backend configuration", "maintenance"),
    ("memory-temperature", "Memory temperature", "Memory temperature support", "maintenance"),
    ("radv", "RADV", "Graphics driver configuration", "advanced"),
    ("video-codec", "Video codecs", "Video codec support", "maintenance"),
    ("proton", "Proton", "Compatibility tools", "maintenance"),
    ("manage", "Component removal and purge", "Review dependency-ordered removal and post-uninstall purge", "maintenance"),
)
CLI_SECTION_IDS = frozenset(section[0] for section in CLI_SECTIONS)
CONTROL_CAPABILITIES = (
    "gpu-voltage-curve", "gpu-ramp-reset", "cpu-oc-update",
    "cpu-unlock-metrics", "cpu-unlock-uninstall", "cli-handoff", "hwmon-sensors",
)


def voltage_arguments(action, frequency, voltage, new_frequency):
    """Validate only consumed values, but require integer placeholders throughout."""
    if type(action) is not str or action not in {
        "set", "add", "edit", "remove", "offset", "reset"
    }:
        raise ValueError("Unknown GPU voltage action.")
    if any(type(value) is not int for value in (frequency, voltage, new_frequency)):
        raise ValueError("GPU voltage values must be whole numbers.")
    if action in {"set", "add", "edit", "remove"} and not 350 <= frequency <= 2230:
        raise ValueError("GPU frequency must be 350-2230 MHz.")
    if action in {"set", "add", "edit"} and not 700 <= voltage <= 1050:
        raise ValueError("GPU voltage must be 700-1050 mV.")
    if action == "edit" and not 350 <= new_frequency <= 2230:
        raise ValueError("New GPU frequency must be 350-2230 MHz.")
    if action == "offset" and not -350 <= voltage <= 350:
        raise ValueError("GPU voltage offset must be -350 to 350 mV.")
    if action in {"set", "add"}:
        return [action, str(frequency), str(voltage)]
    if action == "edit":
        return [action, str(frequency), str(new_frequency), str(voltage)]
    if action == "remove":
        return [action, str(frequency)]
    if action == "offset":
        return [action, str(voltage)]
    return [action]

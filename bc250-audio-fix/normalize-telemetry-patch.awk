BEGIN {
	tables_hunk = 0
	gpu_metrics_hunk = 0
}

/^@@ / {
	tables_hunk = $0 ~ /^@@ -90,17 \+450,24 /
	gpu_metrics_hunk = $0 ~ /^@@ -382,54 \+909,114 /

	if (tables_hunk && legacy_gpu_tables) {
		sub("-90,17", "-90,16")
		sub("\\+450,24", "+450,23")
	}
	if ($0 ~ /^@@ -128,57 \+495,93 /) {
		sub("-128,57", "-128,59")
		sub("\\+495,93", "+495,94")
	}
	if (gpu_metrics_hunk) {
		sub("-382,54", "-382,53")
		sub("\\+909,114", "+909,113")
	}

	print
	next
}

tables_hunk && legacy_gpu_tables && $0 == " \tint ret;" { next }
tables_hunk && legacy_gpu_tables &&
$0 == " \tret = smu_driver_table_init(smu, SMU_DRIVER_TABLE_GPU_METRICS," {
	print " \tsmu_table->gpu_metrics_table_size = sizeof(struct gpu_metrics_v2_2);"
	next
}
tables_hunk && legacy_gpu_tables &&
$0 == " \t\t\t\t    sizeof(struct gpu_metrics_v2_2)," {
	print " \tsmu_table->gpu_metrics_table = kzalloc(smu_table->gpu_metrics_table_size, GFP_KERNEL);"
	next
}
tables_hunk && legacy_gpu_tables &&
$0 == " \t\t\t\t    SMU_GPU_METRICS_CACHE_INTERVAL);" {
	print " \tif (!smu_table->gpu_metrics_table)"
	next
}

gpu_metrics_hunk && legacy_gpu_tables &&
$0 == " \tstruct gpu_metrics_v2_2 *gpu_metrics =" {
	print " \tstruct smu_table_context *smu_table = &smu->smu_table;"
	print
	next
}
gpu_metrics_hunk && legacy_gpu_tables &&
$0 == " \t\t(struct gpu_metrics_v2_2 *)smu_driver_table_ptr(" {
	print " \t\t(struct gpu_metrics_v2_2 *)smu_table->gpu_metrics_table;"
	next
}
gpu_metrics_hunk && legacy_gpu_tables &&
$0 == " \t\t\tsmu, SMU_DRIVER_TABLE_GPU_METRICS);" { next }

$0 == " static const struct smu_feature_bits cyan_skillfish_dpm_features = {" {
	print " #define FEATURE_MASK(feature) (1ULL << feature)"
	next
}
$0 == " \t.bits = {" {
	print " #define SMC_DPM_FEATURE ( \\"
	next
}
$0 == " \t\tSMU_FEATURE_BIT_INIT(FEATURE_FCLK_DPM_BIT)," {
	print " \tFEATURE_MASK(FEATURE_FCLK_DPM_BIT)\t|\t\\"
	next
}
$0 == "-\tsmu_table->metrics_table = kzalloc_obj(SmuMetrics_t);" {
	print "-\tsmu_table->metrics_table = kzalloc(sizeof(SmuMetrics_t), GFP_KERNEL);"
	next
}
$0 == "+\t\tkzalloc_obj(struct cyan_skillfish_metrics_cache);" {
	print "+\t\tkzalloc(sizeof(struct cyan_skillfish_metrics_cache), GFP_KERNEL);"
	next
}
$0 == "-\t\t*value = metrics->Current.CurrentSocketPower;" {
	print "-\t\t*value = (metrics->Current.CurrentSocketPower << 8) /"
	print "-\t\t\t\t1000;"
	next
}
$0 == "-\t\t*value = metrics->Average.CurrentSocketPower;" {
	print "-\t\t*value = (metrics->Average.CurrentSocketPower << 8) /"
	print "-\t\t\t\t1000;"
	next
}
$0 == "+\t\t*value = view.CurrentSocketPower;" {
	print "+\t\t*value = (view.CurrentSocketPower << 8) /"
	print "+\t\t\t\t1000;"
	next
}
$0 == " static int cyan_skillfish_emit_clk_levels(struct smu_context *smu," {
	print " static int cyan_skillfish_print_clk_levels(struct smu_context *smu,"
	next
}
$0 == " \t\t\t\t\t  enum smu_clk_type clk_type, char *buf," {
	print " \t\t\t\t\tenum smu_clk_type clk_type,"
	next
}
$0 == " \t\t\t\t\t  int *offset)" {
	print " \t\t\t\t\tchar *buf)"
	next
}
$0 == " \treturn smu_feature_bits_test_mask(&feature_enabled," {
	print " \treturn !!(feature_enabled & SMC_DPM_FEATURE);"
	next
}
$0 == " \t\t\t\t\t  cyan_skillfish_dpm_features.bits);" { next }

{ print }

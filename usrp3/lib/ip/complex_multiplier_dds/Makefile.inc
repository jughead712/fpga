#
# Copyright 2018 Ettus Research
#

include $(TOOLS_DIR)/make/viv_ip_builder.mak

LIB_IP_COMPLEX_MULTIPLIER_DDS_SRCS = $(IP_BUILD_DIR)/complex_multiplier_dds/complex_multiplier_dds.xci

LIB_IP_COMPLEX_MULTIPLIER_DDS_OUTS = $(addprefix $(IP_BUILD_DIR)/complex_multiplier_dds/, \
complex_multiplier_dds.xci.out \
synth/complex_multiplier_dds.vhd \
) 

$(LIB_IP_COMPLEX_MULTIPLIER_DDS_SRCS) $(LIB_IP_COMPLEX_MULTIPLIER_DDS_OUTS) : $(LIB_IP_DIR)/complex_multiplier_dds/complex_multiplier_dds.xci
	$(call BUILD_VIVADO_IP,complex_multiplier_dds,$(ARCH),$(PART_ID),$(LIB_IP_DIR),$(IP_BUILD_DIR),0)
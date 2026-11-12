# Upstream series: Enable U-Boot boot on MCIMX6UL-EVK

Origin: qemu-devel, 2026-08-12, Bin Meng <bin.meng@processmission.com>
Subject: [PATCH 00/10] hw/arm: Enable U-Boot boot on MCIMX6UL-EVK
Base-commit: e8d693e12af9cbb89d724baadfcc08559669e279

`p00.patch` is the cover letter; `p01.patch` ... `p10.patch` are the original
postings. They do NOT apply on top of `patches/qemu/0001..0016` because those
touch the same files (fsl-imx6ul.c/h, mcimx6ul-evk.c).

`patches/qemu/0017..0026` are the same series rebased onto v11.1.0 with the
project patches applied (only patch 04 needed conflict resolution: the ram-size
property and the `mmdc` MemoryRegion were inserted around the FlexCAN/PWM
additions). Apply order in build-qemu.sh is lexicographic, so 0017+ follow.

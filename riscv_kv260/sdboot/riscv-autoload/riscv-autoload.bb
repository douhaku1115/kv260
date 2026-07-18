SUMMARY = "Auto-load RISC-V(KOZOS) bitstream into PL at boot"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://m_top_kv260.bit \
           file://riscv-load.sh \
           file://riscv-load.service"

S = "${WORKDIR}"

inherit systemd

SYSTEMD_SERVICE:${PN} = "riscv-load.service"
SYSTEMD_AUTO_ENABLE = "enable"

RDEPENDS:${PN} = "bash"

do_install() {
    install -d ${D}${nonarch_base_libdir}/firmware/riscv
    install -m 0644 ${WORKDIR}/m_top_kv260.bit ${D}${nonarch_base_libdir}/firmware/riscv/m_top_kv260.bit

    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/riscv-load.sh ${D}${bindir}/riscv-load.sh

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/riscv-load.service ${D}${systemd_system_unitdir}/riscv-load.service
}

FILES:${PN} += "${nonarch_base_libdir}/firmware/riscv/m_top_kv260.bit \
                ${bindir}/riscv-load.sh \
                ${systemd_system_unitdir}/riscv-load.service"

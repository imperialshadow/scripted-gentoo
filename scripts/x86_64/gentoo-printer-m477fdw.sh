#!/bin/bash
# Copyright (C) 2026 imperialshadow <imperialshadow@protonmail.com>
# Licensed under the GNU General Public License v3.0 or later.
# See the LICENSE file in the project root for details.
# Description: Set up HP Color LaserJet MFP M477fdw via IPP Everywhere (driverless)
set -eo pipefail

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: This script must be run as root."
    exit 1
fi

PRINTER_NAME="HP_M477fdw"

echo "============================================"
echo " HP Color LaserJet MFP M477fdw Setup"
echo "============================================"
echo

read -rp "Printer IP address: " PRINTER_IP
if [[ -z "$PRINTER_IP" ]]; then
    echo "ERROR: IP address required."
    exit 1
fi
echo

echo "Installing CUPS..."
emerge --ask=n --noreplace net-print/cups net-print/cups-filters

echo "Enabling CUPS..."
systemctl enable cups.service
systemctl start cups.service

echo "Adding printer via IPP Everywhere (driverless)..."
lpadmin -p "${PRINTER_NAME}" -E \
    -v "ipp://${PRINTER_IP}/ipp/print" \
    -m everywhere

echo "Setting as default printer..."
lpoptions -d "${PRINTER_NAME}"

echo "Setting duplex (two-sided long edge) as default..."
lpoptions -p "${PRINTER_NAME}" -o sides=two-sided-long-edge

echo "Setting color printing as default..."
lpoptions -p "${PRINTER_NAME}" -o print-color-mode=color

echo
echo "Printer configuration:"
lpoptions -p "${PRINTER_NAME}"
echo
echo "Done. Test with: lp -d ${PRINTER_NAME} /path/to/file.pdf"

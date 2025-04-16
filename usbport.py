"""
list usb port --  Found Orbbec device camera usb port x-x.x, serial number xxx
"""

# Copyright (c) 2025 Orbbec 3D Technology, Inc
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import os


def find_orbbec_devices(vid):

    usb_devices_path = "/sys/bus/usb/devices"
    devices = os.listdir(usb_devices_path)

    print(f"Found Orbbec device:")
    for dev in devices:
        dev_path = os.path.join(usb_devices_path, dev)
        id_vendor_path = os.path.join(dev_path, "idVendor")
        product_path = os.path.join(dev_path, "product")
        serial_path = os.path.join(dev_path, "serial")


        if os.path.exists(id_vendor_path):
            with open(id_vendor_path, 'r') as f:
                vendor_id = f.read().strip()
                if vendor_id == vid:
                    product_name = ""
                    serial_number = ""

                    if os.path.exists(product_path):
                        with open(product_path, 'r') as f:
                            product_name = f.read().strip()

                    if os.path.exists(serial_path):
                        with open(serial_path, 'r') as f:
                            serial_number = f.read().strip()

                    print(f"{product_name}, usb port {dev}, serial number {serial_number}")

def main():
    vid = "2bc5"  # ventor ID
    find_orbbec_devices(vid)

if __name__ == "__main__":
    main()
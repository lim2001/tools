"""
This is example1.py
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


import rclpy
import time
from rclpy.node import Node
from std_msgs.msg import String
import datetime

description = "This is example1.py"

debug_enable =1

def print_debug(*args, **kwargs):
    global debug_enable
    debug_enable = int(debug_enable)
    if debug_enable != 1:
        return
    timestamp = datetime.datetime.now().strftime("[%m %H:%M:%S.%f")[:-3]+ "]"
    print(timestamp, *args, **kwargs)

def func():

    print_debug(f"{description}")

    now = datetime.datetime.now()
    formatted_now = now.strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
    print_debug("format time: ",formatted_now)


if __name__ == '__main__':
    func()
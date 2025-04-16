"""
This is  test2.py, a tool for demo sample
"""
import rclpy
import time
from rclpy.node import Node
from std_msgs.msg import String

import datetime

description = "This is  test2.py, a tool for demo sample"

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
"""
shell_cli.py --- Orbbec Shell Control System v1.0
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

import sys
import subprocess
import os
import re
import pathlib
import rclpy
from rclpy.node import Node
from std_msgs.msg import String
from rclpy.qos import QoSProfile, QoSDurabilityPolicy, QoSReliabilityPolicy

import multiprocessing
import queue
import time
import subprocess
import signal
import shutil

from shell_pub_local import publish_message_local
import time
import datetime
import shlex
from shell_param import set_parameter, get_parameter
import signal

home_dir = os.path.expanduser("~")

debug_enable = 1  # debug print enable


class SHELL_DATA:
    def __init__(self):
        self.srcStrBuf = ""  # 原始命令字符串
        self.srcStrCmd= ""  # 第一个命令
        self.srcStrArg= ""  # 后面参数
        self.argvBuf = ""    # 存储分割的参数字符串
        self.argc = 0        # 参数个数
        self.argv = []       # 存储每个参数的指针列表

def print_debug(*args, **kwargs):
    global debug_enable
    debug_enable = int(debug_enable)

    if debug_enable != 1:
        return

    timestamp = datetime.datetime.now().strftime("[%m %H:%M:%S.%f")[:-3]+ "]"
    print(timestamp, *args, **kwargs)

def shell_help_menu():

    print("**************************************************")
    print("*       ORBBEC AI & ROBOTICS TECHNOLOGIES       *")
    print("*          Shell Control System v1.0             *")
    print("**************************************************")

    print("[ros2]")
    print(" 1: action:          ---  action -- menu: ros2 action xxx xxx    ")
    print(" 2: bag:             --- bag --- menu: ros2 bag")
    print("    ros2 bag record -a     --- record all topic data ")
    print("    ros2 bag record /topic1 /topic2 /topic3  -- record /topic1 /topic2 /topic3 ")
    print("    ros2 bag record -o xxx_bag /cartographer_ros/scan ")
    print("    ros2 bag play     --- start-offset 330 vl_ros2_bag/ ")
    print(" 3: component:        --- component menu:")
    print(" 4: control:           ---  control  menu:")
    print(" 5: daemon:           ---  daemon menu:")
    print(" 6: doctor:           --- check ros setup and other potential issues")
    print(" 7: interface:        --- information about ros interfaces")
    print(" 8: launch:           --- ros2 launch pkgxxx  launch.py    :Run a launch file")
    menu_launch()
    print(" 9: lifecycle:        --- lifecycle  menu:")
    print("10: multicast:        --- multicast  menu:")
    print("11: node:")
    menu_node()
    print("12: param:")
    menu_param()
    print("13: pkg:                --- package  menu")
    print("14: run:                --- ros2 run pkgxxx nodexxx")
    menu_run()
    print("15: security:           --- security menu:")
    print("16: service:            --- service menu:")
    print("    service list        --- service list xxx")
    print("    service call        --- service call  /camera/set_laser_enable std_srvs/srv/SetBool \"{data: false}\"   ")
    print("17: test:               ---  run a ros2 launch test")
    print("18: topic:")
    menu_topic()
    print("19: wtf :               --- use wtf as alias to doctor")
    print()
    print("[cust]")
    print("20: autobuild + pkg      --- eg:  ./autobuild.sh amr --- autobuild = ./autobuild.sh")
    print("21: build + pkg          --- colcon build --cmake-args -DCMAKE_BUILD_TYPE=Release --packages-up-to ")
    print("22: colcon build:")
    print("    colcon build         --- build all ")
    print("    colcon build --cmake-args -DCMAKE_BUILD_TYPE=Release --symlink-install --packages-up-to xxx ")
    print("    colcon list          --- list build pkgxxx ")
    print("23: she                  ---  send shell cmd to robot , the relate sub menu would be show on its node termnal")
    print("    she logen 4          --- self test for check")
    print("    she selftest         --- self test for check")
    print("    she print            --- print msg data for test")
    print("    she log              --- log pkgxxx levelxxx, for set log level")
    print("    she help             --- print help menu")
    print("24: tool:")
    menu_tool()
    print("25: shl:")
    print("    shl           --- search history cmd, eg.  shl orbbec_cam")
    print("    shh           --- list history cmd 20;  use history to list all ")
    print()
    print("------------")
    print("Cmd Example: ")
    print("topic             --- =topic list -v / topic menu")
    print("node              --- node list  / node menu")
    print("launch            --- list  launch menu")
    print("launch  amr_multi_cam bringup_launch.py")
    print("ros2 run rqt_tf_tree rqt_tf_tree")
    print("ros2 run rqt_graph rqt_graph")
    print("pls enter your choice")
    print("***********************************************")
    return 1

# Menu functions for each category
def menu_node():
    """ Node menu """
    print("    node menu:")
    print("    node list             --- list all available node")
    print("    node info nodexxx     --- eg. node info /amr")
    print("    node -h, node list -h, node info -h       --- for related cmd details help of ros2")
    return 1

def menu_topic():
    """ Topic menu """
    print("    topic menu:")
    print("    topic list(topic list -v) --- show topic & menu")
    print("    topic info          --- topic info topicxxx : eg. topic info /shell")
    print("    topic echo          --- topic echo topicxxx : eg. topic echo /cam0/depth/pointcloud --no-arr")
    print("    topic hz            --- topic hz topicxxx : eg. topic hz /cam0/depth/pointcloud")
    print("    topic pub           --- eg. topic pub --once /shell std_msgs/msg/String \"{data: help}\"")
    print("    topic type")
    print("    topic delay")
    print("    topic bw")
    print("    topic -h            --- add -h for related cmd details help of ros2")
    return 1

def menu_param():
    print("    param menu:")
    print("    param get nodexx paramxx          --- eg.  param get /amr filter_")
    print("    param set nodexx paramxx valuexx --- eg.  param set /amr filter_ 3")
    print("    param dump nodexx             --- eg. param dump /amr (or amr), param dump /amr > 123.yaml")
    print("    param list (all)              --- param list nodexxx : eg.  param list /amr")
    print("    param load <node_name> <parameter_file>")
    print("    param delete                --- Delete parameter")
    print("    param describe              --- Show descriptive information about declared parameters")
    print("    Call param <command> -h for the related cmd detailed usage.")
    return 1

def menu_launch():
    print("    launch menu:")
    print("    launch             --- check all of the launch support & menu")
    print("    launch <package_name> <bringup.launch.py>")
    return 1

def menu_run():
    print("    run menu:")
    print("    run                 --- check all of the run support & menu")
    print("    run pkgxx exexx    --- ros2 run <package_name> <executable_name>")
    print("                            eg. ros2 run rqt_tf_tree rqt_tf_tree --force-discover")
    return 1


def menu_tool():
    start_time = time.time()
    tools_paths = set()
    script_dir = pathlib.Path(__file__).parent
    tmp_dir = script_dir / "tmp"
    if tmp_dir.exists():
        shutil.rmtree(tmp_dir)
    tmp_dir.mkdir(exist_ok=True)
    user_home = pathlib.Path.home()
    user_tools_dir = user_home / "tools"
    if (user_tools_dir / "list_menu.py").exists():
        tools_paths.add(str(user_tools_dir))
    current_dir = pathlib.Path.cwd()

    if os.path.basename(current_dir) == "tools":
        if (current_dir / "list_menu.py").exists():
            tools_paths.add(str(current_dir))
    def find_tools_dirs(base_dir, max_depth=4):
        queue = [(base_dir, 0)]
        while queue:
            dir_path, depth = queue.pop(0)
            if depth > max_depth:
                continue

            try:
                with os.scandir(dir_path) as it:
                    for entry in it:
                        if entry.is_dir() and entry.name == "tools":
                            tools_dir = pathlib.Path(entry.path)
                            if (tools_dir / "list_menu.py").exists():
                                tools_paths.add(str(tools_dir))
                        elif entry.is_dir():
                            queue.append((entry.path, depth + 1))
            except PermissionError:
                continue

    find_tools_dirs(current_dir, max_depth=4)

    if not tools_paths:
        print("search tools/list_menu.py not found.")
        return 1

    sorted_tools_paths = sorted(tools_paths, key=len)

    for tools_path in sorted_tools_paths:
        set_parameter('ORBBEC_TOOLS_PATH', tools_path)
        list_menu_file_path = os.path.join(tools_path, 'list_menu.py')

        exec_start = time.time()
        result = subprocess.run(['python3', list_menu_file_path], capture_output=True, text=True)
        exec_time = time.time() - exec_start

        output = result.stdout.splitlines()
        error = result.stderr.splitlines()
        print(f"  {tools_path}")
        for idx, line in enumerate(output, start=1):
            print(f"  {idx:02}. tool {line}")

        if error:
            print(error)

    t4 = time.time()
    for tools_path in sorted_tools_paths:
        for py_file in pathlib.Path(tools_path).glob("*.py"):
            symlink_path = tmp_dir / py_file.name
            if not symlink_path.exists():  # 避免重复创建相同文件的软链接
                symlink_path.symlink_to(py_file)

    return 1


def handle_node(shell_data):
    if shell_data.argc == 1:
        exec_cmd("ros2 node list")
        print()
        menu_node()
    else:
        exec_cmd("ros2 node " + shell_data.srcStrArg)

    return 1

def handle_topic(shell_data):
    if shell_data.argc == 1:
        menu_topic()
        print("------------------------------------------------------\n")
        exec_cmd("ros2 topic list -v")
    else:
        if shell_data.argv[1] =="list":
            exec_cmd("ros2 topic list -v")
        else:
            exec_cmd("ros2 topic " + shell_data.srcStrArg)
    return 1

def handle_param(shell_data):
    if shell_data.argc == 1:
        menu_param()
    elif shell_data.argc == 2 and shell_data.argv[1] == "dump":
        exec_cmd("ros2 param list")
        menu_param()
        print("\n dump should + a node name, e.g.  param dump /cam0")
    else:
        exec_cmd("ros2 param "+ shell_data.srcStrArg)
    return 1

def handle_run(shell_data):
    if shell_data.argc == 1:
        menu_run_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'menu_run.py')
        output = exec_cmd(f"python3 {menu_run_path}")
        print(output)
        menu_run()
        print("\nros2 run <package_name> <executable_name>")
        print("Please choose a package and executable name.")
    else:
        check_and_source_install()
        exec_cmd("ros2 run "+ shell_data.srcStrArg)
    return 1

def handle_launch(shell_data):
    if shell_data.argc == 1:
        menu_run_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'menu_launch.py')
        output = exec_cmd(f"python3 {menu_run_path}")
        print(output)
        menu_launch()
        print("\nros2 launch <package_name> <bringup.launch.py>")
        print("Please choose a package and launch file.")
    else:
        check_and_source_install()
        exec_cmd("ros2 launch "+ shell_data.srcStrArg)
    return 1

def check_and_source_install():
    if 'COLCON_PREFIX_PATH' in os.environ:
        return 1

    shell = os.environ.get('SHELL', '')
    if 'zsh' in shell:
        exec_cmd("source install/setup.zsh")
    elif 'bash' in shell:
        exec_cmd("source install/setup.bash")
    else:
        exec_cmd("source install/setup.zsh")
def exec_cmd_ok(command):
    try:
        print_debug(f"exec cmd: {command}")
        result = subprocess.run(command, shell=True, check=True, text=True, capture_output=True)
        print(result.stdout)
    except subprocess.CalledProcessError as e:
        print(f"Error: {e.stderr}")
    except Exception as e:
        print(f"An unexpected error occurred: {e}")

def exec_cmd(command):
    print(f"--\n{command}\n")
    cmd_list = shlex.split(command)

    try:
        os.execvp(cmd_list[0], cmd_list)  # 直接替换当前进程
    except FileNotFoundError:
        print(f"command not found: {command}", file=sys.stderr)
        return 1
    except Exception as e:
        print(f"command fail: {e}", file=sys.stderr)
        return 1

def exec_cmd2(command):

    cmd_list = shlex.split(command)

    pid = os.fork()
    if pid == 0:

        os.setpgrp()
        try:
            os.execvp(cmd_list[0], cmd_list)
        except FileNotFoundError:
            print(f"not found: {command}", file=sys.stderr)
            sys.exit(1)
        except Exception as e:
            print(f"exec fail: {e}", file=sys.stderr)
            sys.exit(1)
    else:

        try:
            _, status = os.waitpid(pid, 0)
            if os.WIFEXITED(status):
                return os.WEXITSTATUS(status)
            else:
                return 1
        except KeyboardInterrupt:
            os.killpg(pid, signal.SIGTERM)
            print("\nexit", file=sys.stderr)
            return 1

# def exec_ros_cmd1(command):
#     try:
#         print_debug(f"Executing command: {command}")

#         if isinstance(command, list):
#             process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, preexec_fn=os.setsid)
#         else:
#             process = subprocess.Popen(command, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, preexec_fn=os.setsid)

#         print_debug("Waiting for process to complete...")


#         stdout, stderr = process.communicate()

#         print_debug("Process completed.")

#         if stdout:
#             print("stdout:")
#             print(stdout)
#         if stderr:
#             print("stderr:")
#             print(stderr, file=sys.stderr)

#         return stdout if stdout else ""

#     except KeyboardInterrupt:
#         print("KeyboardInterrupt detected. Terminating process...")
#         os.killpg(os.getpgid(process.pid), signal.SIGINT)
#         process.wait()
#         print("\nProcess terminated by user.")
#         return ""

#     except subprocess.CalledProcessError as e:
#         print(f"CalledProcessError: {e.stderr}")
#         return f"Error: {e.stderr}"
#     except Exception as e:
#         print(f"An unexpected error occurred: {e}")
#         return f"An unexpected error occurred: {e}"
def get_history_from_file(file_path, lines=1000):
    """Read the last 'lines' lines from the specified history file."""
    print(f"Reading history from file: {file_path}")
    try:
        # Try different encodings to read the file
        encodings = ['utf-8', 'latin1', 'gbk']
        for encoding in encodings:
            try:
                with open(os.path.expanduser(file_path), 'r', encoding=encoding, errors='ignore') as file:
                    lines_content = file.readlines()[-lines:]
                print(f"Successfully read {len(lines_content)} lines from history file using encoding: {encoding}")
                return ''.join(lines_content)
            except Exception as e:
                print(f"Failed to read file with encoding {encoding}: {e}")
        print("Failed to read file with all tried encodings.")
        return ""
    except FileNotFoundError:
        print(f"File not found: {file_path}")
        return ""
    except Exception as e:
        print(f"Error reading file: {e}")
        return ""

def search_history(pattern):
    """Search for commands in history matching a pattern."""
    print(f"Searching for pattern: {pattern}")
    # Replace '*' with regex for partial matching
    search_pattern = pattern.replace('*', '.*')
    keyword = pattern.replace('*', '')

    # Get last 1000 commands from history
    history_output = get_history_from_file("~/.zsh_history", lines=1000)

    if not history_output:
        print("No history data available.")
        return "Error: Unable to fetch history data."

    print("Processing history data...")
    matching_lines = []

    # Iterate through each line of history
    for line in history_output.splitlines():
        # Remove timestamp and line number (assuming format ": timestamp;command")
        match = re.match(r'^: \d+:\d+;(.*?)$', line)
        if match:
            command = match.group(1).strip()
            # Skip empty lines and comments
            if not command or command.startswith("#"):
                continue
            if re.search(search_pattern, command, re.IGNORECASE):
                print(f"Match found: {command}")
                # Highlight the matched keyword in green
                highlighted = re.sub(f'({keyword})', r'\033[32m\1\033[0m', command, flags=re.IGNORECASE)
                matching_lines.append(highlighted)
        else:
            # Handle lines that do not match the expected format
            if line.strip():  # Skip empty lines
                print(f"Skipping invalid line: {line}")

    if not matching_lines:
        print("No matching lines found.")
        return "No matching commands found in history."

    # Remove duplicates and format the output with line numbers
    unique_history = list(dict.fromkeys(matching_lines))  # Remove duplicates
    final_history = "\n".join([f"{i+1}  {line}" for i, line in enumerate(unique_history[:20])])

    print("Saving results to file...")
    # Save to file and return the result
    with open(os.path.expanduser("~/_data/match_history_cmd.txt"), 'w') as f:
        f.write(final_history)

    return final_history
# Function to display the last 20 unique commands from history
def history_20():
    try:
        command = 'bash -i -c "history -r; history | tail -n 200"'
        result = subprocess.run(command, capture_output=True, text=True, shell=True, executable="/bin/bash")
        history_output = result.stdout.strip()

        if not history_output:
            print("No history found")
            return ""

        print("=== RAW HISTORY (Last 10 lines) ===")
        print("\n".join(history_output.split("\n")[-10:]))

        history_lines = []
        for line in history_output.split("\n"):
            match = re.match(r'^\s*\d+\s+(.+)$', line)
            if match:
                history_lines.append(match.group(1))
            else:
                history_lines.append(line)

        print("=== PROCESSED HISTORY (Last 10 lines) ===")
        print("\n".join(history_lines[-10:]))


        history_lines.reverse()

        # 去重（保持最新记录在前）
        seen = set()
        unique_history = []
        for cmd in history_lines:
            if cmd not in seen:
                seen.add(cmd)
                unique_history.append(cmd)

        final_history = "\n".join(f"{i+1}  {cmd}" for i, cmd in enumerate(unique_history[:30]))

        print("\n=== FINAL PROCESSED HISTORY (First 10 lines) ===")
        print("\n".join(final_history.split("\n")[:10]))
        with open(os.path.expanduser("~/.auto_history_cmd.txt"), 'w') as f:
            f.write(final_history + "\n")

        return final_history

    except Exception as e:
        print(f"Error: {e}")
        return ""

# Function to handle the auto-history feature
def handle_shh(shell_data=None):

    if shell_data is None or not shell_data.srcStrArg.strip():
        return history_20()

    if shell_data.srcStrArg.isdigit() and 1 <= int(shell_data.srcStrArg) <= 30:
        # Retrieve the command from the saved history file
        command_file = os.path.expanduser("~/.auto_history_cmd.txt")
        if not os.path.exists(command_file):
            return f"File {command_file} does not exist."

        with open(command_file, 'r') as f:
            history_lines = f.readlines()

        try:
            command = history_lines[int(shell_data.srcStrArg) - 1].split("  ", 1)[-1]
        except IndexError:
            return f"Unable to retrieve line {shell_data.srcStrArg} from the history."

        # Remove any ANSI escape sequences
        command = re.sub(r'\033\[[0-9;]*m', '', command)
        return exec_cmd(command)

    else:
        # Search and display history matching input
        return search_history(shell_data.srcStrArg)

def handle_shell(shell_data):
    shell_help_menu()
    return 1  # Return 1 to indicate command is processed

def handle_she(shell_data):
    message = shell_data.srcStrArg.strip()  # 获取并去掉首尾空格
    # print(f"handle_she: {message}")
    if not message:
        message = "none"

    # publish_message(message)
    publish_message_local(message)

    return 1

def handle_tool(shell_data):

    if shell_data.argc == 1:
        menu_tool()
    elif shell_data.argc >= 2:
        arg1 = shell_data.argv[1]
        # tools_path = get_parameter('ORBBEC_TOOLS_PATH')
        # list_menu_file_path = os.path.join(os.path.expanduser(tools_path), 'list_menu.py')
        # if not os.path.isfile(list_menu_file_path):
        #     menu_tool()
        #     tools_path = get_parameter('ORBBEC_TOOLS_PATH')
        #     list_menu_file_path = os.path.join(os.path.expanduser(tools_path), 'list_menu.py')

        script_dir = pathlib.Path(__file__).parent
        tmp_dir = script_dir / "tmp"
        if not os.path.isfile(os.path.join(tmp_dir, arg1)):
            menu_tool()

        command = f"python3 {tmp_dir / shell_data.srcStrArg}"
        # result = subprocess.run(command, stdout=sys.stdout, stderr=sys.stderr)
        exec_cmd(command)

    return 1

def handle_config(shell_data):
    if shell_data.argc == 1:
        debug_enable = get_parameter('PRINT_DEBUG_ENABLE')
        print(f"get_parameter debug {debug_enable}")
    elif shell_data.argc >= 2:
        debug_enable = shell_data.argv[1]
        print(f"set_parameter debug {shell_data.srcStrBuf}")
        set_parameter('PRINT_DEBUG_ENABLE', debug_enable)
    else:
        print(f"param warning, e.g. setparam 1 or 0")
    return 1

def handle_check(shell_data):
    # 检查当前路径是否为 ROS 2 工作空间
    current_dir = os.getcwd()
    install_dir = os.path.join(current_dir, 'install')
    setup_file = os.path.join(install_dir, 'setup.zsh')

    if os.path.exists(install_dir) and os.path.exists(setup_file):
        print(f"Current directory is a ROS 2 workspace: {current_dir}")
    else:
        print(f"Current directory is not a ROS 2 workspace: {current_dir}")


    # 检查环境变量
    required_env_vars = ['COLCON_PREFIX_PATH', 'CMAKE_PREFIX_PATH']
    for var in required_env_vars:
        if var in os.environ:
            print(f"\n{var} is set: {os.environ[var]}")
        else:
            print(f"\n{var} is not set.")
        # print("\n")

    print()
    # 检查 Shell 版本
    shell = os.environ.get('SHELL', '')
    if shell:
        try:
            result = subprocess.run([shell, '--version'], capture_output=True, text=True)
            print(f"Shell: {result.stdout.strip()}")
        except subprocess.CalledProcessError as e:
            print(f"Failed to get shell version: {e.stderr.strip()}")
    else:
        print("SHELL environment variable is not set.")

    print()
    # 检查 Ubuntu 版本
    try:
        result = subprocess.run(['lsb_release', '-ds'], capture_output=True, text=True)
        print(f"Ubuntu version: {result.stdout.strip()}")
    except subprocess.CalledProcessError as e:
        print(f"Failed to get Ubuntu version: {e.stderr.strip()}")

    print()
    # 检查 CPU 信息
    def get_cpu_info():
        try:
            cpu_info = subprocess.check_output("lscpu", universal_newlines=True)
            cpu_details = {}
            for line in cpu_info.split("\n"):
                if "Model name:" in line:
                    cpu_details['Model'] = line.split(":")[1].strip()
                elif "Vendor ID:" in line:
                    cpu_details['Vendor'] = line.split(":")[1].strip()
                elif "CPU MHz:" in line:
                    cpu_details['Frequency MHz'] = line.split(":")[1].strip()
                elif "CPU max MHz:" in line:
                    cpu_details['Frequency max MHz'] = line.split(":")[1].strip()
                elif "CPU(s):" in line and "NUMA" not in line:
                    cpu_details['Core Count'] = line.split(":")[1].strip()
                elif "Architecture:" in line:
                    cpu_details['Architecture'] = line.split(":")[1].strip()

            return cpu_details
        except Exception as e:
            print(f"Error fetching CPU info: {e}")
            return {}

    output_lines = []
    # Print CPU info
    cpu_info = get_cpu_info()
    for key, value in cpu_info.items():
        print(f"{key}: {value}")
        output_lines.append(f"{key}: {value}")

    return 1

def handle(shell_data):
    print(f"handle {shell_data.srcStrBuf}")
    return 1

def print_shell_data(shell_data):
    print("---------------------------")
    print(f"srcStrBuf: {shell_data.srcStrBuf}")
    print(f"srcStrArg: {shell_data.srcStrArg}")
    print(f"argc: {shell_data.argc}")
    print(f"argv[0]: {shell_data.argv[0]}")
    return 1

def read_config_debug_param():
    debug_enable=get_parameter('PRINT_DEBUG_ENABLE')
    if debug_enable is None:
        debug_enable = 0
        set_parameter('PRINT_DEBUG_ENABLE', debug_enable)
    # print_debug(f"debug_enable = {debug_enable}")
    return 1

def main(cmd):

    shell_data = SHELL_DATA()
    shell_data.srcStrBuf = cmd  # Store raw command string
    cmd_parts = cmd.split()
    shell_data.argv = cmd_parts
    shell_data.argc = len(cmd_parts)

    # shell_data.srcStrArg = shell_data.srcStrBuf.split()[1:]
    shell_data.srcStrArg = ' '.join(shell_data.argv[1:])

    print_shell_data(shell_data)

    if shell_data.argc == 0:
        return 0

    match shell_data.argv[0]:
        case 'topic' | 'to':
            read_config_debug_param()
            handle_topic(shell_data)
        case 'service' | 'se':
            read_config_debug_param()
            handle(shell_data)
        case 'node':
            read_config_debug_param()
            handle_node(shell_data)
        case 'run':
            read_config_debug_param()
            handle_run(shell_data)
        case 'launch':
            read_config_debug_param()
            handle_launch(shell_data)
        case 'param':
            read_config_debug_param()
            handle_param(shell_data)
        case 'shell' | 'sh':
            read_config_debug_param()
            handle_shell(shell_data)
        case 'she':
            read_config_debug_param()
            handle_she(shell_data)
        case 'shhh':
            read_config_debug_param()
            handle_shh(shell_data)
        case 'tool':
            read_config_debug_param()
            handle_tool(shell_data)
        case 'cfg':
            read_config_debug_param()
            handle_config(shell_data)
        case 'check':
            read_config_debug_param()
            handle_check(shell_data)
        case _:
            return 0  # If no matching command, return 0

    return 1

if __name__ == "__main__":
    cmd = sys.argv[1]  # Get the input command string
    result = main(cmd)  # Parse and handle the command
    sys.exit(result)  # Return processing result, 0 for not processed, 1 for processed

"""
cpu test details --- output: CPU usage for each orbbec camera, and create reslut file save in ~/_data/cpu_test/
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

import subprocess
import re
import time
import csv
import os
import numpy as np
import matplotlib.pyplot as plt
from collections import deque
from datetime import datetime


user_home_dir = os.path.expanduser("~")
output_dir = os.path.join(user_home_dir, "_data", "cpu_test")

# Create a dynamic filename with date and time in the format _ddhh_mmss
timestamp = datetime.now().strftime("_%d%H_%M%S")

output_file_path = f'{output_dir}/cpu_report{timestamp}.log'
csv_file_path = f'{output_dir}/cpu_report{timestamp}.csv'

# Ensure the directory exists
os.makedirs(output_dir, exist_ok=True)

# Dictionary to store CPU usage history for each process (1-minute window)
cpu_usage_history = {}
# Deque to store the total CPU usage for the last 1 minute
total_cpu_usage_deque = deque(maxlen=3)  # 30 samples for 1 minute with a 2-second interval
total_cpu_usage_all_processes_deque = deque(maxlen=3)  # 30 samples for 1 minute with 2-second interval

def get_cpu_info():
    """Get CPU information including model, manufacturer, frequency, and core count."""
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

def get_cpu_usage_and_load_average_from_top():
    try:
        # Run the top command and capture the output
        top_output = subprocess.check_output(['top', '-b', '-n', '1'], universal_newlines=True)

        # Extract Load Average
        load_avg_match = re.search(r'load average: ([\d\.]+), ([\d\.]+), ([\d\.]+)', top_output)
        if load_avg_match:
            load_avg_1 = float(load_avg_match.group(1))
            load_avg_5 = float(load_avg_match.group(2))
            load_avg_15 = float(load_avg_match.group(3))
        else:
            load_avg_1 = load_avg_5 = load_avg_15 = 0.0

        # Get CPU core count
        cpu_core_count = int(subprocess.check_output(['nproc'], universal_newlines=True).strip())

        # Filter lines containing 'component_conta' or 'nodelet'
        # filtered_lines = [line for line in top_output.split('\n') if re.search(r'component_conta|nodelet|ob_benchmark', line)]
        filtered_lines = [line for line in top_output.split('\n') if re.search(r'component_conta|nodelet|ob_benchmark', line)]

        # Filter lines for all processes excluding 0% and 'rviz' to calculate total CPU usage of all processes
        filtered_lines_all = [line for line in top_output.split('\n') if len(line.split()) >= 12]

        processes_info = []
        total_cpu_usage = 0
        total_cpu_usage_all_processes = 0
        current_pids = set()  # Track current PIDs

        # Parse the filtered lines for component_conta
        for line in filtered_lines:
            fields = line.split()

            pid = fields[0]
            cpu_usage = float(fields[8])  # %CPU column in top output


            command = fields[11]
            current_pids.add(pid)  # Add to current PID set

            if pid not in cpu_usage_history:
                # Initialize deque for 1-minute sliding window (30 samples assuming 2s interval)
                cpu_usage_history[pid] = deque(maxlen=30)

            # Update deque with the current CPU usage
            cpu_usage_history[pid].append(cpu_usage)

            # Calculate the average of the last 1 minute
            average_cpu = sum(cpu_usage_history[pid]) / len(cpu_usage_history[pid])

            processes_info.append({
                'pid': pid,
                'name': command,
                'cpu_percent': cpu_usage,
                'average_cpu_percent': average_cpu
            })
            total_cpu_usage += cpu_usage

        # Parse the filtered lines for all processes to calculate total CPU usage for all processes
        for line in filtered_lines_all:
            fields = line.split()
            if len(fields) < 12:
                continue  # Skip lines that don't have enough data

            pid = fields[0]
            try:
                cpu_usage = float(fields[8])  # %CPU column in top output
            except ValueError:
                continue  # Skip lines with invalid CPU usage

            if cpu_usage == 0 or 'rviz' in fields[11]:  # Skip processes with 0% CPU usage or containing 'rviz'
                continue

            total_cpu_usage_all_processes += cpu_usage

        # Clean up entries for PIDs that are no longer active
        for pid in list(cpu_usage_history.keys()):
            if pid not in current_pids:
                del cpu_usage_history[pid]

        total_cpu_usage_all_processes_deque.append(total_cpu_usage_all_processes)
        average_total_cpu_usage_all_processes = sum(total_cpu_usage_all_processes_deque) / len(total_cpu_usage_all_processes_deque) if total_cpu_usage_all_processes_deque else 0
        return processes_info, total_cpu_usage, total_cpu_usage_all_processes, average_total_cpu_usage_all_processes, (load_avg_1, load_avg_5, load_avg_15), cpu_core_count

    except Exception as e:
        print(f"Error occurred: {e}")
        return [], 0, 0, 0, (0.0, 0.0, 0.0), 0  # Return default values in case of error

def save_to_file(content):
    with open(output_file_path, 'a') as file:
        file.write(content + '\n')

def save_to_csv(timestamp, processes_info, total_cpu_usage, total_cpu_usage_all_processes, average_total_cpu_usage_all_processes, load_avg_1):
    with open(csv_file_path, 'a', newline='') as csvfile:
        fieldnames = ['timestamp', 'pid', 'name', 'cpu_percent', 'average_cpu_percent', 'total_cpu_usage', 'total_cpu_usage_all_processes', 'average_total_cpu_usage_all_processes', 'load_avg_1']
        writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
        if csvfile.tell() == 0:
            writer.writeheader()

        for info in processes_info:
            writer.writerow({
                'timestamp': timestamp,
                'pid': info['pid'],
                'name': info['name'],
                'cpu_percent': f"{info['cpu_percent']:.2f}",  # Rounded to 2 decimal places
                'average_cpu_percent': f"{info['average_cpu_percent']:.2f}",  # Rounded to 2 decimal places
                'total_cpu_usage': f"{total_cpu_usage:.2f}",  # Rounded to 2 decimal places
                'total_cpu_usage_all_processes': f"{total_cpu_usage_all_processes:.2f}",  # Rounded to 2 decimal places
                'average_total_cpu_usage_all_processes': f"{average_total_cpu_usage_all_processes:.2f}",  # Rounded to 2 decimal places
                'load_avg_1': f"{load_avg_1:.2f}"  # Rounded to 2 decimal places
            })

def plot_cpu_usage(csv_file_path, test_duration):
    data = {}
    timestamps_set = set()

    with open(csv_file_path, 'r') as csvfile:
        reader = csv.DictReader(csvfile)
        for row in reader:
            timestamp = row['timestamp']
            pid = row['pid']
            average_cpu_percent = float(row['average_cpu_percent'])
            load_avg_1 = float(row['load_avg_1'])

            if pid not in data:
                data[pid] = {'timestamps': [], 'average_cpu_percents': []}
            data[pid]['timestamps'].append(timestamp)
            data[pid]['average_cpu_percents'].append(average_cpu_percent)

            timestamps_set.add(timestamp)
        timestamps = sorted(timestamps_set)
    aligned_data = {pid: {'timestamps': [], 'average_cpu_percents': []} for pid in data}
    for pid, pid_data in data.items():
        pid_timestamps = pid_data['timestamps']
        pid_cpu_data = pid_data['average_cpu_percents']
        for timestamp in timestamps:
            if timestamp in pid_timestamps:
                index = pid_timestamps.index(timestamp)
                aligned_data[pid]['timestamps'].append(timestamp)
                aligned_data[pid]['average_cpu_percents'].append(pid_cpu_data[index])
            else:
                aligned_data[pid]['timestamps'].append(timestamp)
                aligned_data[pid]['average_cpu_percents'].append(np.nan)

    load_avg_1_data = {'timestamps': [], 'load_avg_1': []}
    with open(csv_file_path, 'r') as csvfile:
        reader = csv.DictReader(csvfile)
        for row in reader:
            load_avg_1_data['timestamps'].append(row['timestamp'])
            load_avg_1_data['load_avg_1'].append(float(row['load_avg_1']))
    aligned_load_avg_1 = []
    for timestamp in timestamps:
        if timestamp in load_avg_1_data['timestamps']:
            index = load_avg_1_data['timestamps'].index(timestamp)
            aligned_load_avg_1.append(load_avg_1_data['load_avg_1'][index])
        else:
            aligned_load_avg_1.append(np.nan)
    plt.figure(figsize=(12, 6))
    for pid, pid_data in aligned_data.items():
        timestamps = pid_data['timestamps']
        cpu_usage = pid_data['average_cpu_percents']
        plt.plot(timestamps, cpu_usage, label=f'PID {pid}')


    plt.plot(timestamps, aligned_load_avg_1, label='Load Avg 1min', linestyle='--', color='black')

    plt.xlabel('Time')
    plt.ylabel('CPU Usage (%)')
    plt.title(f'Orbbec Camera CPU Usage vs Load Average. total{test_duration:.1f} min')
    plt.legend()
    plt.xticks(rotation=45)
    plt.tight_layout()

    # Save the plot as an image file
    plot_file_path = csv_file_path.replace('.csv', '.png')
    plt.savefig(plot_file_path)
    plt.close()
    return plot_file_path

if __name__ == "__main__":
    test_start_time = datetime.now().strftime("%H:%M:%S")
    print(f"Test started at: {test_start_time}")
    start_time = time.time()
    total_iterations = 0
    output_lines = []
    # Print CPU info
    cpu_info = get_cpu_info()
    for key, value in cpu_info.items():
        print(f"{key}: {value}")
        output_lines.append(f"{key}: {value}")

    print("--------------------------------------------------------------")
    output_lines.append("--------------------------------------------------------------")

    try:
        while True:
            total_iterations += 1
            processes_info, total_cpu_usage, total_cpu_usage_all_processes, average_total_cpu_usage_all_processes, load_averages, cpu_core_count = get_cpu_usage_and_load_average_from_top()

            total_cpu_usage_deque.append(total_cpu_usage)
            average_total_cpu_usage = sum(total_cpu_usage_deque) / len(total_cpu_usage_deque) if total_cpu_usage_deque else 0
            processes_info.sort(key=lambda x: int(x['pid']))

            for info in processes_info:
                line = f"Orbbec {info['name']}_pid{info['pid']}: {info['cpu_percent']:5.2f}%, average {info['average_cpu_percent']:5.2f}%"
                output_lines.append(line)
                print(line)

            total_devices = len(processes_info)
            elapsed_time_minutes = (time.time() - start_time) / 60
            summary_line = (f"Total Orbbec devices: {total_devices},  sum :{total_cpu_usage:5.2f}%, "
                            f"average {average_total_cpu_usage:5.2f}%")
            print(summary_line)
            output_lines.append(summary_line)

            # Print the total CPU usage for all processes excluding 0% and rviz
            print(f"Total processes (excluding rviz): {total_cpu_usage_all_processes:.2f}%, "
                  f"average {average_total_cpu_usage_all_processes:.2f}%")
            output_lines.append(f"Total processes (excluding rviz): {total_cpu_usage_all_processes:.2f}%, "
                                f"average {average_total_cpu_usage_all_processes:.2f}%")

            print(f"Total test time: {elapsed_time_minutes:.2f}min, count: {total_iterations}")
            output_lines.append(f"Total test time: {elapsed_time_minutes:.2f}min, count: {total_iterations}")

            load_avg_1, load_avg_5, load_avg_15 = load_averages
            load_avg_line = (f"System CPU load average: {load_avg_1:.2f}, {load_avg_5:.2f}, {load_avg_15:.2f} ---- "
                             f"({(load_avg_1/cpu_core_count)*100:.2f}%, {(load_avg_5/cpu_core_count)*100:.2f}%, "
                             f"{(load_avg_15/cpu_core_count)*100:.2f}%: CPU core total {cpu_core_count})")
            print(load_avg_line)
            output_lines.append(load_avg_line)

            print("--------------------------------------------------------------")
            output_lines.append("--------------------------------------------------------------")

            save_to_file('\n'.join(output_lines))
            save_to_csv(datetime.now().strftime("%H:%M:%S"), processes_info, total_cpu_usage, total_cpu_usage_all_processes, average_total_cpu_usage_all_processes, (load_avg_1/cpu_core_count)*100)

            time.sleep(2)
    except KeyboardInterrupt:
        test_end_time = datetime.now().strftime("%H:%M:%S")
        test_duration = (time.time() - start_time) / 60  # Total test time in minutes
        print(f"Test ended at: {test_end_time}")
        print(f"Total test time: {test_duration:.2f} minutes")
        print("\nTerminating and generating plot.")
        plot_file_path = plot_cpu_usage(csv_file_path, test_duration)

        # Print output file paths
        print(f"save file {output_file_path}")
        print(f"save file {csv_file_path}")
        print(f"save file {plot_file_path}")

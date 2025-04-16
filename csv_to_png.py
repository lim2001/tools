'''
to transfer cpu test data of cvs to png
'''

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

import csv
import matplotlib.pyplot as plt
from matplotlib.ticker import MaxNLocator
import sys

def plot_cpu_usage(csv_file_path):
    data = {}
    load_avg_1_data = {'timestamps': [], 'load_avg_1': []}
    added_timestamps = set()  # 用于记录已经添加的时间戳

    with open(csv_file_path, 'r') as csvfile:
        reader = csv.DictReader(csvfile)
        for row in reader:
            timestamp = row['timestamp']
            pid = row['pid']
            average_cpu_percent = round(float(row['average_cpu_percent']), 2)
            load_avg_1 = round(float(row['load_avg_1']), 2)

            if pid not in data:
                data[pid] = {'timestamps': [], 'average_cpu_percents': []}
            data[pid]['timestamps'].append(timestamp)
            data[pid]['average_cpu_percents'].append(average_cpu_percent)

            # 收集每个时间戳对应的load_avg_1值
            if timestamp not in added_timestamps:
                load_avg_1_data['timestamps'].append(timestamp)
                load_avg_1_data['load_avg_1'].append(load_avg_1)
                added_timestamps.add(timestamp)

    # print("Data collected from CSV:")
    # for pid, pid_data in data.items():
    #     print(f"PID {pid}:")
    #     print(f"  Timestamps: {pid_data['timestamps']}")
    #     print(f"  CPU Percents: {pid_data['average_cpu_percents']}")
    # print("Load Avg 1 Data:")
    # print(f"  Timestamps: {load_avg_1_data['timestamps']}")
    # print(f"  Load Avg 1: {load_avg_1_data['load_avg_1']}")
    plt.figure(figsize=(12, 6))
    for pid, pid_data in data.items():
        plt.plot(pid_data['timestamps'], pid_data['average_cpu_percents'], label=f'PID {pid}')

    plt.plot(load_avg_1_data['timestamps'], load_avg_1_data['load_avg_1'], label='Load Avg 1min', linestyle='--', color='black')

    plt.title("CPU Usage Monitoring")
    plt.xlabel('Time')
    plt.ylabel('CPU Usage (%)')
    plt.legend(loc='upper left')

    # Limit the number of X-axis labels
    x_labels = load_avg_1_data['timestamps']
    max_labels = 50  # Maximum number of labels to display
    num_ticks = min(len(x_labels), max_labels)

    # Use MaxNLocator to create evenly spaced tick locations
    plt.gca().xaxis.set_major_locator(MaxNLocator(nbins=num_ticks))

    plt.xticks(rotation=45, ha='right')  # Rotate x-axis labels for better readability

    plt.tight_layout()

    # Save the plot as an image file
    plot_file_path = csv_file_path.replace('.csv', '_.png')
    plt.savefig(plot_file_path)
    plt.close()
    return plot_file_path

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python script.py <csv_file_path>")
        sys.exit(1)

    csv_file_path = sys.argv[1]

    plot_file_path = plot_cpu_usage(csv_file_path)
    print(f"Plot saved to {plot_file_path}")
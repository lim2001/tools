import subprocess

def launch_robot():
    # 定义要启动的 launch 文件
    launch_files = [
        "ros2 launch turn_on_wheeltec_robot turn_on_wheeltec_robot.launch.py",
        "ros2 launch oradar_lidar ms200_scan_view.launch.py",
        "ros2 run wheeltec_robot_keyboard wheeltec_keyboard",
        "ros2 launch orbbec_camera astra_stereo_u3.launch.py"
    ]

    # 启动每个 launch 文件
    processes = []
    for launch_file in launch_files:
        print(f"Starting: {launch_file}")
        process = subprocess.Popen(launch_file.split(), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        processes.append(process)

    print("All launch files started successfully.")

    # 等待所有子进程完成
    for process in processes:
        process.wait()

if __name__ == "__main__":
    launch_robot()
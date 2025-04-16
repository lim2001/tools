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
import json
import pathlib

current_dir = os.path.dirname(os.path.abspath(__file__))


config_file_path = os.path.join(current_dir, 'config.json')


def config_file_exists():
    return os.path.exists(config_file_path)


def read_config():
    if not config_file_exists():
        print("config.json not found, creating a new one...")
        with open(config_file_path, 'w') as file:
            json.dump({}, file, indent=4)

    with open(config_file_path, 'r') as file:
        return json.load(file)



def check_parameter_exists(parameter):
    config = read_config()
    if config and parameter in config:
        return True
    return False


def get_parameter(parameter):
    config = read_config()
    if config and parameter in config:
        return config[parameter]
    else:
        print(f"param {parameter} not found")
        return None


def set_parameter(parameter, value):
    if isinstance(value, pathlib.Path):
        value = str(value)

    if not config_file_exists():
        print("config.json not found")
        return
    config = read_config()
    if config is not None:
        config[parameter] = value
        with open(config_file_path, 'w') as file:
            json.dump(config, file, indent=4)
        # print(f"set {parameter}  {value}")

if __name__ == "__main__":
    if config_file_exists():
        print("config.json exist")

        if check_parameter_exists('ORBBEC_TOOLS_PATH'):
            print(f"ORBBEC_TOOLS_PATH: {get_parameter('ORBBEC_TOOLS_PATH')}")
        else:
            print("ORBBEC_TOOLS_PATH not found")

        set_parameter('ORBBEC_SHELL_PATH', '/new/path/to/orbbec/shell')

    else:
        print("config.json not found")

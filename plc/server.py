from pymodbus.datastore import ModbusDeviceContext, ModbusSequentialDataBlock, ModbusServerContext
from pymodbus.server import StartTcpServer

REGISTER_COUNT = 10

# pymodbus 3.15 renamed ModbusSlaveContext -> ModbusDeviceContext and dropped the
# synchronous context[0].setValues() convenience method (the old datastore API is
# deprecated in favor of SimData/SimDevice). No live-incrementing register for now:
# static values are enough to produce a real Modbus read/write for Zeek to observe.


def main():
    # ModbusSequentialDataBlock's starting address is 1-based internally in this
    # pymodbus version (it builds SimData(address - 1, ...)); address=0 raises.
    device = ModbusDeviceContext(
        di=ModbusSequentialDataBlock(1, [0] * REGISTER_COUNT),
        co=ModbusSequentialDataBlock(1, [0] * REGISTER_COUNT),
        hr=ModbusSequentialDataBlock(1, [42] * REGISTER_COUNT),
        ir=ModbusSequentialDataBlock(1, [0] * REGISTER_COUNT),
    )
    context = ModbusServerContext(devices=device, single=True)

    print("Modbus/TCP server listening on 0.0.0.0:502", flush=True)
    StartTcpServer(context=context, address=("0.0.0.0", 502))


if __name__ == "__main__":
    main()

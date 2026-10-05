import asyncio
import time

from pymodbus.server import StartAsyncTcpServer
from pymodbus.simulator import DataType, SimData, SimDevice

REGISTER_COUNT = 10
TICK_SECONDS = 2
STARTED = time.monotonic()

# Uses the SimData/SimDevice API: in pymodbus 3.15 the older datastore
# classes (ModbusDeviceContext/ModbusServerContext) are deprecated, and
# their get/set calls just return DEVICE_BUSY, so a live value can't be
# pushed into them from outside the server.


async def on_request(func_code, _device_id, _address, _count, registers, _values):
    # Called before every request is served. Holding register 0 is a counter
    # that goes up by one every TICK_SECONDS since start, so reads look like
    # live telemetry. Computed on demand instead of by a background loop.
    registers[0] = int((time.monotonic() - STARTED) // TICK_SECONDS) & 0xFFFF
    return None


def bits():
    return [SimData(0, count=REGISTER_COUNT, values=False, datatype=DataType.BITS)]


def registers(value):
    return [SimData(0, count=REGISTER_COUNT, values=value, datatype=DataType.REGISTERS)]


async def main():
    # (coils, discrete inputs, holding registers, input registers)
    device = SimDevice(
        id=0,
        simdata=(bits(), bits(), registers(42), registers(0)),
        action=on_request,
    )
    print("Modbus/TCP server listening on 0.0.0.0:502", flush=True)
    await StartAsyncTcpServer(context=device, address=("0.0.0.0", 502))


if __name__ == "__main__":
    asyncio.run(main())

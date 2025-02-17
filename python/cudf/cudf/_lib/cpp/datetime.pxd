from libcpp.memory cimport unique_ptr

from cudf._lib.cpp.column.column cimport column
from cudf._lib.cpp.column.column_view cimport column_view
from cudf._lib.cpp.scalar.scalar cimport scalar


cdef extern from "cudf/datetime.hpp" namespace "cudf::datetime" nogil:
    cdef unique_ptr[column] extract_year(const column_view& column) except +
    cdef unique_ptr[column] extract_month(const column_view& column) except +
    cdef unique_ptr[column] extract_day(const column_view& column) except +
    cdef unique_ptr[column] extract_weekday(const column_view& column) except +
    cdef unique_ptr[column] extract_hour(const column_view& column) except +
    cdef unique_ptr[column] extract_minute(const column_view& column) except +
    cdef unique_ptr[column] extract_second(const column_view& column) except +
    cdef unique_ptr[column] ceil_day(const column_view& column) except +
    cdef unique_ptr[column] ceil_hour(const column_view& column) except +
    cdef unique_ptr[column] ceil_minute(const column_view& column) except +
    cdef unique_ptr[column] ceil_second(const column_view& column) except +
    cdef unique_ptr[column] ceil_millisecond(
        const column_view& column
    ) except +
    cdef unique_ptr[column] ceil_microsecond(
        const column_view& column
    ) except +
    cdef unique_ptr[column] ceil_nanosecond(
        const column_view& column
    ) except +
    cdef unique_ptr[column] floor_day(const column_view& column) except +
    cdef unique_ptr[column] floor_hour(const column_view& column) except +
    cdef unique_ptr[column] floor_minute(const column_view& column) except +
    cdef unique_ptr[column] floor_second(const column_view& column) except +
    cdef unique_ptr[column] floor_millisecond(
        const column_view& column
    ) except +
    cdef unique_ptr[column] floor_microsecond(
        const column_view& column
    ) except +
    cdef unique_ptr[column] floor_nanosecond(
        const column_view& column
    ) except +
    cdef unique_ptr[column] round_day(const column_view& column) except +
    cdef unique_ptr[column] round_hour(const column_view& column) except +
    cdef unique_ptr[column] round_minute(const column_view& column) except +
    cdef unique_ptr[column] round_second(const column_view& column) except +
    cdef unique_ptr[column] round_millisecond(
        const column_view& column
    ) except +
    cdef unique_ptr[column] round_microsecond(
        const column_view& column
    ) except +
    cdef unique_ptr[column] round_nanosecond(
        const column_view& column
    ) except +
    cdef unique_ptr[column] add_calendrical_months(
        const column_view& timestamps,
        const column_view& months
    ) except +
    cdef unique_ptr[column] day_of_year(const column_view& column) except +
    cdef unique_ptr[column] is_leap_year(const column_view& column) except +
    cdef unique_ptr[column] last_day_of_month(
        const column_view& column
    ) except +
    cdef unique_ptr[column] extract_quarter(const column_view& column) except +
    cdef unique_ptr[column] days_in_month(const column_view& column) except +

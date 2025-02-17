from libcpp.memory cimport unique_ptr
from libcpp.utility cimport move

cimport cudf._lib.cpp.datetime as libcudf_datetime
from cudf._lib.column cimport Column
from cudf._lib.cpp.column.column cimport column
from cudf._lib.cpp.column.column_view cimport column_view
from cudf._lib.cpp.filling cimport calendrical_month_sequence
from cudf._lib.cpp.types cimport size_type
from cudf._lib.scalar cimport DeviceScalar


def add_months(Column col, Column months):
    # months must be int16 dtype
    cdef unique_ptr[column] c_result
    cdef column_view col_view = col.view()
    cdef column_view months_view = months.view()

    with nogil:
        c_result = move(
            libcudf_datetime.add_calendrical_months(
                col_view,
                months_view
            )
        )

    return Column.from_unique_ptr(move(c_result))


def extract_datetime_component(Column col, object field):

    cdef unique_ptr[column] c_result
    cdef column_view col_view = col.view()

    with nogil:
        if field == "year":
            c_result = move(libcudf_datetime.extract_year(col_view))
        elif field == "month":
            c_result = move(libcudf_datetime.extract_month(col_view))
        elif field == "day":
            c_result = move(libcudf_datetime.extract_day(col_view))
        elif field == "weekday":
            c_result = move(libcudf_datetime.extract_weekday(col_view))
        elif field == "hour":
            c_result = move(libcudf_datetime.extract_hour(col_view))
        elif field == "minute":
            c_result = move(libcudf_datetime.extract_minute(col_view))
        elif field == "second":
            c_result = move(libcudf_datetime.extract_second(col_view))
        elif field == "day_of_year":
            c_result = move(libcudf_datetime.day_of_year(col_view))
        else:
            raise ValueError(f"Invalid datetime field: '{field}'")

    result = Column.from_unique_ptr(move(c_result))

    if field == "weekday":
        # Pandas counts Monday-Sunday as 0-6
        # while we count Monday-Sunday as 1-7
        result = result.binary_operator("sub", result.dtype.type(1))

    return result


def ceil_datetime(Column col, object field):
    cdef unique_ptr[column] c_result
    cdef column_view col_view = col.view()

    with nogil:
        # https://pandas.pydata.org/pandas-docs/version/0.25.0/reference/api/pandas.Timedelta.resolution.html
        if field == "D":
            c_result = move(libcudf_datetime.ceil_day(col_view))
        elif field == "H":
            c_result = move(libcudf_datetime.ceil_hour(col_view))
        elif field == "T" or field == "min":
            c_result = move(libcudf_datetime.ceil_minute(col_view))
        elif field == "S":
            c_result = move(libcudf_datetime.ceil_second(col_view))
        elif field == "L" or field == "ms":
            c_result = move(libcudf_datetime.ceil_millisecond(col_view))
        elif field == "U" or field == "us":
            c_result = move(libcudf_datetime.ceil_microsecond(col_view))
        elif field == "N":
            c_result = move(libcudf_datetime.ceil_nanosecond(col_view))
        else:
            raise ValueError(f"Invalid resolution: '{field}'")

    result = Column.from_unique_ptr(move(c_result))
    return result


def floor_datetime(Column col, object field):
    cdef unique_ptr[column] c_result
    cdef column_view col_view = col.view()

    with nogil:
        # https://pandas.pydata.org/docs/reference/api/pandas.Timedelta.resolution_string.html
        if field == "D":
            c_result = move(libcudf_datetime.floor_day(col_view))
        elif field == "H":
            c_result = move(libcudf_datetime.floor_hour(col_view))
        elif field == "T" or field == "min":
            c_result = move(libcudf_datetime.floor_minute(col_view))
        elif field == "S":
            c_result = move(libcudf_datetime.floor_second(col_view))
        elif field == "L" or field == "ms":
            c_result = move(libcudf_datetime.floor_millisecond(col_view))
        elif field == "U" or field == "us":
            c_result = move(libcudf_datetime.floor_microsecond(col_view))
        elif field == "N":
            c_result = move(libcudf_datetime.floor_nanosecond(col_view))
        else:
            raise ValueError(f"Invalid resolution: '{field}'")

    result = Column.from_unique_ptr(move(c_result))
    return result


def round_datetime(Column col, object field):
    cdef unique_ptr[column] c_result
    cdef column_view col_view = col.view()

    with nogil:
        # https://pandas.pydata.org/docs/reference/api/pandas.Timedelta.resolution_string.html
        if field == "D":
            c_result = move(libcudf_datetime.round_day(col_view))
        elif field == "H":
            c_result = move(libcudf_datetime.round_hour(col_view))
        elif field == "T" or field == "min":
            c_result = move(libcudf_datetime.round_minute(col_view))
        elif field == "S":
            c_result = move(libcudf_datetime.round_second(col_view))
        elif field == "L" or field == "ms":
            c_result = move(libcudf_datetime.round_millisecond(col_view))
        elif field == "U" or field == "us":
            c_result = move(libcudf_datetime.round_microsecond(col_view))
        elif field == "N":
            c_result = move(libcudf_datetime.round_nanosecond(col_view))
        else:
            raise ValueError(f"Invalid resolution: '{field}'")

    result = Column.from_unique_ptr(move(c_result))
    return result


def is_leap_year(Column col):
    """Returns a boolean indicator whether the year of the date is a leap year
    """
    cdef unique_ptr[column] c_result
    cdef column_view col_view = col.view()

    with nogil:
        c_result = move(libcudf_datetime.is_leap_year(col_view))

    return Column.from_unique_ptr(move(c_result))


def date_range(DeviceScalar start, size_type n, offset):
    cdef unique_ptr[column] c_result
    cdef size_type months = (
        offset.kwds.get("years", 0) * 12
        + offset.kwds.get("months", 0)
    )

    with nogil:
        c_result = move(calendrical_month_sequence(
            n,
            start.c_value.get()[0],
            months
        ))
    return Column.from_unique_ptr(move(c_result))


def extract_quarter(Column col):
    """
    Returns a column which contains the corresponding quarter of the year
    for every timestamp inside the input column.
    """
    cdef unique_ptr[column] c_result
    cdef column_view col_view = col.view()

    with nogil:
        c_result = move(libcudf_datetime.extract_quarter(col_view))

    return Column.from_unique_ptr(move(c_result))


def days_in_month(Column col):
    """Extracts the number of days in the month of the date
    """
    cdef unique_ptr[column] c_result
    cdef column_view col_view = col.view()

    with nogil:
        c_result = move(libcudf_datetime.days_in_month(col_view))

    return Column.from_unique_ptr(move(c_result))


def last_day_of_month(Column col):
    cdef unique_ptr[column] c_result
    cdef column_view col_view = col.view()

    with nogil:
        c_result = move(libcudf_datetime.last_day_of_month(col_view))

    return Column.from_unique_ptr(move(c_result))

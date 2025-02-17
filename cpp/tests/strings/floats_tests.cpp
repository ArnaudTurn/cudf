/*
 * Copyright (c) 2019-2021, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <cudf/strings/convert/convert_floats.hpp>
#include <cudf/strings/strings_column_view.hpp>

#include <tests/strings/utilities.h>
#include <cudf_test/base_fixture.hpp>
#include <cudf_test/column_utilities.hpp>
#include <cudf_test/column_wrapper.hpp>

#include <vector>

constexpr cudf::test::debug_output_level verbosity{cudf::test::debug_output_level::ALL_ERRORS};

struct StringsConvertTest : public cudf::test::BaseFixture {
};

TEST_F(StringsConvertTest, IsFloat)
{
  cudf::test::strings_column_wrapper strings;
  auto strings_view = cudf::strings_column_view(strings);
  auto results      = cudf::strings::is_float(strings_view);
  EXPECT_EQ(cudf::type_id::BOOL8, results->view().type().id());
  EXPECT_EQ(0, results->view().size());

  cudf::test::strings_column_wrapper strings1({"+175",
                                               "-9.8",
                                               "7+2",
                                               "+-4",
                                               "6.7e17",
                                               "-1.2e-5",
                                               "e",
                                               ".e",
                                               "1.e+-2",
                                               "00.00",
                                               "1.0e+1.0",
                                               "1.2.3",
                                               "+",
                                               "--",
                                               ""});
  results = cudf::strings::is_float(cudf::strings_column_view(strings1));
  cudf::test::fixed_width_column_wrapper<bool> expected1(
    {1, 1, 0, 0, 1, 1, 1, 1, 0, 1, 0, 0, 0, 0, 0});
  CUDF_TEST_EXPECT_COLUMNS_EQUAL(*results, expected1);

  cudf::test::strings_column_wrapper strings2(
    {"-34", "9.8", "1234567890", "-917.2e5", "INF", "NAN", "-Inf", "INFINITY"});
  results = cudf::strings::is_float(cudf::strings_column_view(strings2));
  cudf::test::fixed_width_column_wrapper<bool> expected2({1, 1, 1, 1, 1, 1, 1, 1});
  CUDF_TEST_EXPECT_COLUMNS_EQUAL(*results, expected2);
}

TEST_F(StringsConvertTest, ToFloats32)
{
  std::vector<const char*> h_strings{
    "1234",    nullptr,        "-876",     "543.2",
    "-0.12",   ".25",          "-.002",    "",
    "-0.0",    "1.2e4",        "NAN",      "abc123",
    "123abc",  "456e",         "-1.78e+5", "-122.33644782123456789",
    "12e+309", "3.4028236E38", "INF",      "Infinity"};
  cudf::test::strings_column_wrapper strings(
    h_strings.begin(),
    h_strings.end(),
    thrust::make_transform_iterator(h_strings.begin(), [](auto str) { return str != nullptr; }));

  std::vector<float> h_expected;
  std::for_each(h_strings.begin(), h_strings.end(), [&](const char* str) {
    h_expected.push_back(str ? std::atof(str) : 0);
  });

  auto strings_view = cudf::strings_column_view(strings);
  auto results = cudf::strings::to_floats(strings_view, cudf::data_type{cudf::type_id::FLOAT32});

  cudf::test::fixed_width_column_wrapper<float> expected(
    h_expected.begin(),
    h_expected.end(),
    thrust::make_transform_iterator(h_strings.begin(), [](auto str) { return str != nullptr; }));
  CUDF_TEST_EXPECT_COLUMNS_EQUIVALENT(*results, expected, verbosity);
}

TEST_F(StringsConvertTest, FromFloats32)
{
  std::vector<float> h_floats{100,
                              654321.25,
                              -12761.125,
                              0,
                              5,
                              -4,
                              std::numeric_limits<float>::quiet_NaN(),
                              839542223232.79,
                              -0.0};
  std::vector<const char*> h_expected{
    "100.0", "654321.25", "-12761.125", "0.0", "5.0", "-4.0", "NaN", "8.395422433e+11", "-0.0"};

  cudf::test::fixed_width_column_wrapper<float> floats(
    h_floats.begin(),
    h_floats.end(),
    thrust::make_transform_iterator(h_expected.begin(), [](auto str) { return str != nullptr; }));

  auto results = cudf::strings::from_floats(floats);

  cudf::test::strings_column_wrapper expected(
    h_expected.begin(),
    h_expected.end(),
    thrust::make_transform_iterator(h_expected.begin(), [](auto str) { return str != nullptr; }));

  CUDF_TEST_EXPECT_COLUMNS_EQUIVALENT(*results, expected, verbosity);
}

TEST_F(StringsConvertTest, ToFloats64)
{
  std::vector<const char*> h_strings{
    "1234",   nullptr,    "-876",     "543.2",         "-0.12",   ".25",
    "-.002",  "",         "-0.0",     "1.28e256",      "NaN",     "abc123",
    "123abc", "456e",     "-1.78e+5", "-122.33644782", "12e+309", "1.7976931348623159E308",
    "-Inf",   "-INFINITY"};
  cudf::test::strings_column_wrapper strings(
    h_strings.begin(),
    h_strings.end(),
    thrust::make_transform_iterator(h_strings.begin(), [](auto str) { return str != nullptr; }));

  std::vector<double> h_expected;
  std::for_each(h_strings.begin(), h_strings.end(), [&](const char* str) {
    h_expected.push_back(str ? std::atof(str) : 0);
  });

  auto strings_view = cudf::strings_column_view(strings);
  auto results = cudf::strings::to_floats(strings_view, cudf::data_type{cudf::type_id::FLOAT64});

  cudf::test::fixed_width_column_wrapper<double> expected(
    h_expected.begin(),
    h_expected.end(),
    thrust::make_transform_iterator(h_strings.begin(), [](auto str) { return str != nullptr; }));
  CUDF_TEST_EXPECT_COLUMNS_EQUIVALENT(*results, expected, verbosity);
}

TEST_F(StringsConvertTest, FromFloats64)
{
  std::vector<double> h_floats{100,
                               654321.25,
                               -12761.125,
                               0,
                               5,
                               -4,
                               std::numeric_limits<double>::quiet_NaN(),
                               839542223232.794248339,
                               -0.0};
  std::vector<const char*> h_expected{
    "100.0", "654321.25", "-12761.125", "0.0", "5.0", "-4.0", "NaN", "8.395422232e+11", "-0.0"};

  cudf::test::fixed_width_column_wrapper<double> floats(
    h_floats.begin(),
    h_floats.end(),
    thrust::make_transform_iterator(h_expected.begin(), [](auto str) { return str != nullptr; }));

  auto results = cudf::strings::from_floats(floats);

  cudf::test::strings_column_wrapper expected(
    h_expected.begin(),
    h_expected.end(),
    thrust::make_transform_iterator(h_expected.begin(), [](auto str) { return str != nullptr; }));

  CUDF_TEST_EXPECT_COLUMNS_EQUIVALENT(*results, expected, verbosity);
}

TEST_F(StringsConvertTest, ZeroSizeStringsColumnFloat)
{
  cudf::column_view zero_size_column(
    cudf::data_type{cudf::type_id::FLOAT32}, 0, nullptr, nullptr, 0);
  auto results = cudf::strings::from_floats(zero_size_column);
  cudf::test::expect_strings_empty(results->view());
}

TEST_F(StringsConvertTest, ZeroSizeFloatsColumn)
{
  cudf::column_view zero_size_column(
    cudf::data_type{cudf::type_id::STRING}, 0, nullptr, nullptr, 0);
  auto results =
    cudf::strings::to_floats(zero_size_column, cudf::data_type{cudf::type_id::FLOAT32});
  EXPECT_EQ(0, results->size());
}

TEST_F(StringsConvertTest, FromToFloatsError)
{
  auto dtype  = cudf::data_type{cudf::type_id::INT32};
  auto column = cudf::make_numeric_column(dtype, 100);
  EXPECT_THROW(cudf::strings::from_floats(column->view()), cudf::logic_error);

  cudf::test::strings_column_wrapper strings{"this string intentionally left blank"};
  EXPECT_THROW(cudf::strings::to_floats(column->view(), dtype), cudf::logic_error);
}

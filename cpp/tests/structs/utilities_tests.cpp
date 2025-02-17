/*
 * Copyright (c) 2021, NVIDIA CORPORATION.
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

#include <cudf_test/base_fixture.hpp>
#include <cudf_test/column_utilities.hpp>
#include <cudf_test/column_wrapper.hpp>
#include <cudf_test/cudf_gtest.hpp>
#include <cudf_test/iterator_utilities.hpp>
#include <cudf_test/table_utilities.hpp>
#include <cudf_test/type_lists.hpp>

#include <cudf/column/column_factories.hpp>
#include <cudf/detail/aggregation/aggregation.hpp>
#include <cudf/detail/null_mask.hpp>
#include <cudf/detail/structs/utilities.hpp>
#include <cudf/null_mask.hpp>

namespace cudf::test {

/**
 * @brief Round-trip input table through flatten/unflatten,
 *        verify that the table remains equivalent.
 */
void flatten_unflatten_compare(table_view const& input_table)
{
  using namespace cudf::structs::detail;

  auto flattened = flatten_nested_columns(input_table, {}, {}, column_nullability::FORCE);
  auto unflattened =
    unflatten_nested_columns(std::make_unique<cudf::table>(flattened), input_table);

  CUDF_TEST_EXPECT_TABLES_EQUIVALENT(input_table, unflattened->view());
}

using namespace cudf;
using namespace iterators;
using strings    = strings_column_wrapper;
using dictionary = dictionary_column_wrapper<std::string>;
using structs    = structs_column_wrapper;

template <typename T>
using nums = fixed_width_column_wrapper<T, int32_t>;

template <typename T>
using lists = lists_column_wrapper<T, int32_t>;

struct StructUtilitiesTest : BaseFixture {
};

template <typename T>
struct TypedStructUtilitiesTest : StructUtilitiesTest {
};

TYPED_TEST_SUITE(TypedStructUtilitiesTest, FixedWidthTypes);

TYPED_TEST(TypedStructUtilitiesTest, ListsAtTopLevelUnsupported)
{
  using T     = TypeParam;
  using lists = lists_column_wrapper<T, int32_t>;
  using nums  = fixed_width_column_wrapper<T, int32_t>;

  auto lists_col = lists{{0, 1}, {22, 33}, {44, 55, 66}};
  auto nums_col  = nums{{0, 1, 2}, null_at(6)};

  EXPECT_THROW(flatten_unflatten_compare(cudf::table_view{{lists_col, nums_col}}),
               cudf::logic_error);
}

TYPED_TEST(TypedStructUtilitiesTest, NestedListsUnsupported)
{
  using T     = TypeParam;
  using lists = lists_column_wrapper<T, int32_t>;
  using nums  = fixed_width_column_wrapper<T, int32_t>;

  auto lists_member = lists{{0, 1}, {22, 33}, {44, 55, 66}};
  auto nums_member  = nums{{0, 1, 2}, null_at(6)};
  auto structs_col  = structs{{nums_member, lists_member}};

  auto nums_col = nums{{0, 1, 2}, null_at(6)};

  EXPECT_THROW(flatten_unflatten_compare(cudf::table_view{{nums_col, structs_col}}),
               cudf::logic_error);
}

TYPED_TEST(TypedStructUtilitiesTest, NoStructs)
{
  using T    = TypeParam;
  using nums = fixed_width_column_wrapper<T, int32_t>;

  auto nums_col        = nums{{0, 1, 22, 33, 44, 55, 66}, null_at(0)};
  auto strings_col     = strings{{"", "1", "22", "333", "4444", "55555", "666666"}, null_at(1)};
  auto nuther_nums_col = nums{{0, 1, 2, 3, 4, 5, 6}, null_at(6)};

  flatten_unflatten_compare(cudf::table_view{{nums_col, strings_col, nuther_nums_col}});
}

TYPED_TEST(TypedStructUtilitiesTest, SingleLevelStruct)
{
  using T    = TypeParam;
  using nums = fixed_width_column_wrapper<T, int32_t>;

  auto nums_member    = nums{{0, 1, 22, 333, 44, 55, 66}, null_at(0)};
  auto strings_member = strings{{"", "1", "22", "333", "4444", "55555", "666666"}, null_at(1)};
  auto structs_col    = structs{{nums_member, strings_member}};
  auto nums_col       = nums{{0, 1, 2, 3, 4, 5, 6}, null_at(6)};

  flatten_unflatten_compare(cudf::table_view{{nums_col, structs_col}});
}

TYPED_TEST(TypedStructUtilitiesTest, SingleLevelStructWithNulls)
{
  using T    = TypeParam;
  using nums = fixed_width_column_wrapper<T, int32_t>;

  auto nums_member    = nums{{0, 1, 22, 333, 44, 55, 66}, null_at(0)};
  auto strings_member = strings{{"", "1", "22", "333", "4444", "55555", "666666"}, null_at(1)};
  auto structs_col    = structs{{nums_member, strings_member}, null_at(2)};
  auto nums_col       = nums{{0, 1, 2, 3, 4, 5, 6}, null_at(6)};

  flatten_unflatten_compare(cudf::table_view{{nums_col, structs_col}});
}

TYPED_TEST(TypedStructUtilitiesTest, StructOfStruct)
{
  using T    = TypeParam;
  using nums = fixed_width_column_wrapper<T, int32_t>;

  auto nums_col = nums{{0, 1, 2, 3, 4, 5, 6}, null_at(6)};

  auto struct_0_nums_member = nums{{0, 1, 22, 33, 44, 55, 66}, null_at(0)};
  auto struct_0_strings_member =
    strings{{"", "1", "22", "333", "4444", "55555", "666666"}, null_at(1)};
  auto structs_1_structs_member = structs{{struct_0_nums_member, struct_0_strings_member}};

  auto struct_1_nums_member  = nums{{0, 1, 22, 33, 44, 55, 66}, null_at(3)};
  auto struct_of_structs_col = structs{{struct_1_nums_member, structs_1_structs_member}};

  flatten_unflatten_compare(cudf::table_view{{nums_col, struct_of_structs_col}});
}

TYPED_TEST(TypedStructUtilitiesTest, StructOfStructWithNullsAtLeafLevel)
{
  using T    = TypeParam;
  using nums = fixed_width_column_wrapper<T, int32_t>;

  auto nums_col = nums{{0, 1, 2, 3, 4, 5, 6}, null_at(6)};

  auto struct_0_nums_member = nums{{0, 1, 22, 33, 44, 55, 66}, null_at(0)};
  auto struct_0_strings_member =
    strings{{"", "1", "22", "333", "4444", "55555", "666666"}, null_at(1)};
  auto structs_1_structs_member =
    structs{{struct_0_nums_member, struct_0_strings_member}, null_at(2)};

  auto struct_1_nums_member  = nums{{0, 1, 22, 33, 44, 55, 66}, null_at(3)};
  auto struct_of_structs_col = structs{{struct_1_nums_member, structs_1_structs_member}};

  flatten_unflatten_compare(cudf::table_view{{nums_col, struct_of_structs_col}});
}

TYPED_TEST(TypedStructUtilitiesTest, StructOfStructWithNullsAtTopLevel)
{
  using T    = TypeParam;
  using nums = fixed_width_column_wrapper<T, int32_t>;

  auto nums_col = nums{{0, 1, 2, 3, 4, 5, 6}, null_at(6)};

  auto struct_0_nums_member = nums{{0, 1, 22, 33, 44, 55, 66}, null_at(0)};
  auto struct_0_strings_member =
    strings{{"", "1", "22", "333", "4444", "55555", "666666"}, null_at(1)};
  auto structs_1_structs_member = structs{{struct_0_nums_member, struct_0_strings_member}};

  auto struct_1_nums_member = nums{{0, 1, 22, 33, 44, 55, 66}, null_at(3)};
  auto struct_of_structs_col =
    structs{{struct_1_nums_member, structs_1_structs_member}, null_at(4)};

  flatten_unflatten_compare(cudf::table_view{{nums_col, struct_of_structs_col}});
}

TYPED_TEST(TypedStructUtilitiesTest, StructOfStructWithNullsAtAllLevels)
{
  using T    = TypeParam;
  using nums = fixed_width_column_wrapper<T, int32_t>;

  auto nums_col = nums{{0, 1, 2, 3, 4, 5, 6}, null_at(6)};

  auto struct_0_nums_member = nums{{0, 1, 22, 33, 44, 55, 66}, null_at(0)};
  auto struct_0_strings_member =
    strings{{"", "1", "22", "333", "4444", "55555", "666666"}, null_at(1)};
  auto structs_1_structs_member =
    structs{{struct_0_nums_member, struct_0_strings_member}, null_at(2)};

  auto struct_1_nums_member = nums{{0, 1, 22, 33, 44, 55, 66}, null_at(3)};
  auto struct_of_structs_col =
    structs{{struct_1_nums_member, structs_1_structs_member}, null_at(4)};

  flatten_unflatten_compare(cudf::table_view{{nums_col, struct_of_structs_col}});
}

TYPED_TEST(TypedStructUtilitiesTest, ListsAreUnsupported)
{
  using T    = TypeParam;
  using ints = fixed_width_column_wrapper<int32_t>;
  using lcw  = lists_column_wrapper<T, int32_t>;

  // clang-format off
  auto lists_member = lcw{  {0,1,2}, {3,4,5}, {6,7,8,9} };
  auto ints_member  = ints{       0,       1,         2 };
  // clang-format on

  auto structs_with_lists_col = structs{lists_member, ints_member};

  EXPECT_THROW(flatten_unflatten_compare(cudf::table_view{{structs_with_lists_col}}),
               cudf::logic_error);
}

struct SuperimposeTest : StructUtilitiesTest {
};

template <typename T>
struct TypedSuperimposeTest : StructUtilitiesTest {
};

TYPED_TEST_SUITE(TypedSuperimposeTest, FixedWidthTypes);

void test_non_struct_columns(cudf::column_view const& input)
{
  // superimpose_parent_nulls() on non-struct columns should return the input column, unchanged.
  auto [superimposed, backing_validity_buffers] =
    cudf::structs::detail::superimpose_parent_nulls(input);

  CUDF_TEST_EXPECT_COLUMNS_EQUIVALENT(input, superimposed);
  EXPECT_TRUE(backing_validity_buffers.empty());
}

TYPED_TEST(TypedSuperimposeTest, NoStructInput)
{
  using T = TypeParam;

  test_non_struct_columns(fixed_width_column_wrapper<T>{{6, 5, 4, 3, 2, 1, 0}, null_at(3)});
  test_non_struct_columns(
    lists_column_wrapper<T, int32_t>{{{6, 5}, {4, 3}, {2, 1}, {0}}, null_at(3)});
  test_non_struct_columns(strings{{"All", "The", "Leaves", "Are", "Brown"}, null_at(3)});
  test_non_struct_columns(dictionary{{"All", "The", "Leaves", "Are", "Brown"}, null_at(3)});
}

/**
 * @brief Helper to construct a numeric member of a struct column.
 */
template <typename T, typename NullIter>
nums<T> make_nums_member(NullIter null_iter = no_nulls())
{
  return nums<T>{{10, 11, 12, 13, 14, 15, 16}, null_iter};
}

/**
 * @brief Helper to construct a lists member of a struct column.
 */
template <typename T, typename NullIter>
lists<T> make_lists_member(NullIter null_iter = no_nulls())
{
  return lists<T>{{{20, 20}, {21, 21}, {22, 22}, {23, 23}, {24, 24}, {25, 25}, {26, 26}},
                  null_iter};
}

TYPED_TEST(TypedSuperimposeTest, BasicStruct)
{
  using T = TypeParam;

  auto nums_member   = make_nums_member<T>(nulls_at({3, 6}));
  auto lists_member  = make_lists_member<T>(nulls_at({4, 5}));
  auto structs_input = structs{{nums_member, lists_member}, no_nulls()}.release();

  // Reset STRUCTs' null-mask. Mark first STRUCT row as null.
  auto structs_view = structs_input->mutable_view();
  cudf::detail::set_null_mask(structs_view.null_mask(), 0, 1, false);

  // At this point, the STRUCT nulls aren't pushed down to members,
  // even though the parent null-mask was modified.
  CUDF_TEST_EXPECT_COLUMNS_EQUIVALENT(structs_view.child(0), make_nums_member<T>(nulls_at({3, 6})));
  CUDF_TEST_EXPECT_COLUMNS_EQUIVALENT(structs_view.child(1),
                                      make_lists_member<T>(nulls_at({4, 5})));

  auto [output, backing_buffers] = cudf::structs::detail::superimpose_parent_nulls(structs_view);

  // After superimpose_parent_nulls(), the struct nulls (i.e. at index-0) should have been pushed
  // down to the children. All members should have nulls at row-index 0.
  auto expected_nums_member    = make_nums_member<T>(nulls_at({0, 3, 6}));
  auto expected_lists_member   = make_lists_member<T>(nulls_at({0, 4, 5}));
  auto expected_structs_output = structs{{expected_nums_member, expected_lists_member}, null_at(0)};

  CUDF_TEST_EXPECT_COLUMNS_EQUIVALENT(output, expected_structs_output);
}

TYPED_TEST(TypedSuperimposeTest, NonNullableParentStruct)
{
  // Test that if the parent struct is not nullable, non-struct members should
  // remain unchanged.

  using T = TypeParam;

  auto nums_member   = make_nums_member<T>(nulls_at({3, 6}));
  auto lists_member  = make_lists_member<T>(nulls_at({4, 5}));
  auto structs_input = structs{{nums_member, lists_member}, no_nulls()}.release();

  auto [output, backing_buffers] =
    cudf::structs::detail::superimpose_parent_nulls(structs_input->view());

  // After superimpose_parent_nulls(), none of the child structs should have changed,
  // because the parent had no nulls to begin with.
  auto expected_nums_member    = make_nums_member<T>(nulls_at({3, 6}));
  auto expected_lists_member   = make_lists_member<T>(nulls_at({4, 5}));
  auto expected_structs_output = structs{{expected_nums_member, expected_lists_member}, no_nulls()};

  CUDF_TEST_EXPECT_COLUMNS_EQUIVALENT(output, expected_structs_output);
}

TYPED_TEST(TypedSuperimposeTest, NestedStruct_ChildNullable_ParentNonNullable)
{
  // Test with Struct<Struct>. If the parent struct is not nullable:
  //   1. Non-struct members should remain unchanged.
  //   2. Member-structs should have their respective nulls pushed down into grandchildren.

  using T = TypeParam;

  auto nums_member          = make_nums_member<T>(nulls_at({3, 6}));
  auto lists_member         = make_lists_member<T>(nulls_at({4, 5}));
  auto outer_struct_members = std::vector<std::unique_ptr<cudf::column>>{};
  outer_struct_members.push_back(structs{{nums_member, lists_member}, no_nulls()}.release());

  // Reset STRUCTs' null-mask. Mark first STRUCT row as null.
  auto structs_view = outer_struct_members.back()->mutable_view();
  cudf::detail::set_null_mask(structs_view.null_mask(), 0, 1, false);

  auto structs_of_structs = structs{std::move(outer_struct_members)}.release();

  auto [output, backing_buffers] =
    cudf::structs::detail::superimpose_parent_nulls(structs_of_structs->view());

  // After superimpose_parent_nulls(), outer-struct column should not have pushed nulls to child
  // structs. But the child struct column must push its nulls to its own children.
  auto expected_nums_member  = make_nums_member<T>(nulls_at({0, 3, 6}));
  auto expected_lists_member = make_lists_member<T>(nulls_at({0, 4, 5}));
  auto expected_structs      = structs{{expected_nums_member, expected_lists_member}, null_at(0)};
  auto expected_structs_of_structs = structs{{expected_structs}};

  CUDF_TEST_EXPECT_COLUMNS_EQUIVALENT(output, expected_structs_of_structs);
}

TYPED_TEST(TypedSuperimposeTest, NestedStruct_ChildNullable_ParentNullable)
{
  // Test with Struct<Struct>.
  // If both the parent struct and the child are nullable, the leaf nodes should
  // have a 3-way ANDed null-mask.

  using T = TypeParam;

  auto nums_member          = make_nums_member<T>(nulls_at({3, 6}));
  auto lists_member         = make_lists_member<T>(nulls_at({4, 5}));
  auto outer_struct_members = std::vector<std::unique_ptr<cudf::column>>{};
  outer_struct_members.push_back(structs{{nums_member, lists_member}, no_nulls()}.release());

  // Reset STRUCTs' null-mask. Mark first STRUCT row as null.
  auto structs_view = outer_struct_members.back()->mutable_view();
  auto num_rows     = structs_view.size();
  cudf::detail::set_null_mask(structs_view.null_mask(), 0, 1, false);

  auto structs_of_structs =
    structs{std::move(outer_struct_members), std::vector<bool>(num_rows, true)}.release();

  // Modify STRUCT-of-STRUCT's null-mask. Mark second STRUCT row as null.
  auto structs_of_structs_view = structs_of_structs->mutable_view();
  cudf::detail::set_null_mask(structs_of_structs_view.null_mask(), 1, 2, false);

  auto [output, backing_buffers] =
    cudf::structs::detail::superimpose_parent_nulls(structs_of_structs->view());

  // After superimpose_parent_nulls(), outer-struct column should not have pushed nulls to child
  // structs. But the child struct column must push its nulls to its own children.
  auto expected_nums_member  = make_nums_member<T>(nulls_at({0, 1, 3, 6}));
  auto expected_lists_member = make_lists_member<T>(nulls_at({0, 1, 4, 5}));
  auto expected_structs = structs{{expected_nums_member, expected_lists_member}, nulls_at({0, 1})};
  auto expected_structs_of_structs = structs{{expected_structs}, null_at(1)};

  CUDF_TEST_EXPECT_COLUMNS_EQUIVALENT(output, expected_structs_of_structs);
}

cudf::column_view slice_off_first_and_last_rows(cudf::column_view const& col)
{
  return cudf::slice(col, {1, col.size() - 1})[0];
}

void mark_row_as_null(cudf::mutable_column_view const& col, size_type row_index)
{
  cudf::detail::set_null_mask(col.null_mask(), row_index, row_index + 1, false);
}

TYPED_TEST(TypedSuperimposeTest, Struct_Sliced)
{
  // Test with a sliced STRUCT column.
  // Ensure that superimpose_parent_nulls() produces the right results, even when the input is
  // sliced.

  using T = TypeParam;

  auto nums_member    = make_nums_member<T>(nulls_at({3, 6}));
  auto lists_member   = make_lists_member<T>(nulls_at({4, 5}));
  auto structs_column = structs{{nums_member, lists_member}, no_nulls()}.release();

  // Reset STRUCTs' null-mask. Mark second STRUCT row as null.
  mark_row_as_null(structs_column->mutable_view(), 1);

  // The null masks should now look as follows, with the STRUCT null mask *not* pushed down:
  // STRUCT:       1111101
  // nums_member:  0110111
  // lists_member: 1001111

  // Slice off the first and last rows.
  auto sliced_structs = slice_off_first_and_last_rows(structs_column->view());

  // After slice(), the null masks will be:
  // STRUCT:       11110
  // nums_member:  11011
  // lists_member: 00111

  auto [output, backing_buffers] = cudf::structs::detail::superimpose_parent_nulls(sliced_structs);

  // After superimpose_parent_nulls(), the null masks should be:
  // STRUCT:       11110
  // nums_member:  11010
  // lists_member: 00110

  // Construct expected columns using structs_column_wrapper, which should push the parent nulls
  // down automatically. Then, slice() off the ends.
  auto expected_nums             = make_nums_member<T>(nulls_at({1, 3, 6}));
  auto expected_lists            = make_lists_member<T>(nulls_at({1, 4, 5}));
  auto expected_unsliced_structs = structs{{expected_nums, expected_lists}, nulls_at({1})};
  auto expected_structs          = slice_off_first_and_last_rows(expected_unsliced_structs);

  CUDF_TEST_EXPECT_COLUMNS_EQUIVALENT(output, expected_structs);
}

TYPED_TEST(TypedSuperimposeTest, NestedStruct_Sliced)
{
  // Test with a sliced STRUCT<STRUCT> column.
  // Ensure that superimpose_parent_nulls() produces the right results, even when the input is
  // sliced.

  using T = TypeParam;

  auto nums_member           = make_nums_member<T>(nulls_at({3, 6}));
  auto lists_member          = make_lists_member<T>(nulls_at({4, 5}));
  auto structs_column        = structs{{nums_member, lists_member}, null_at(1)};
  auto struct_structs_column = structs{{structs_column}, no_nulls()}.release();

  // Reset STRUCT<STRUCT>'s null-mask. Mark third row as null.
  mark_row_as_null(struct_structs_column->mutable_view(), 2);

  // The null masks should now look as follows, with the STRUCT<STRUCT> null mask *not* pushed down:
  // STRUCT<STRUCT>: 1111011
  // STRUCT:         1111101
  // nums_member:    0110101
  // lists_member:   1001101

  // Slice off the first and last rows.
  auto sliced_structs = slice_off_first_and_last_rows(struct_structs_column->view());

  // After slice(), the null masks will be:
  // STRUCT<STRUCT>: 11101
  // STRUCT:         11110
  // nums_member:    11010
  // lists_member:   00110

  auto [output, backing_buffers] = cudf::structs::detail::superimpose_parent_nulls(sliced_structs);

  // After superimpose_parent_nulls(), the null masks will be:
  // STRUCT<STRUCT>: 11101
  // STRUCT:         11100
  // nums_member:    11000
  // lists_member:   00100

  // Construct expected columns using structs_column_wrapper, which should push the parent nulls
  // down automatically. Then, slice() off the ends.
  auto expected_nums           = make_nums_member<T>(nulls_at({3, 6}));
  auto expected_lists          = make_lists_member<T>(nulls_at({4, 5}));
  auto expected_structs        = structs{{expected_nums, expected_lists}, nulls_at({1})};
  auto expected_struct_structs = structs{{expected_structs}, null_at(2)};
  auto expected_sliced_structs = slice_off_first_and_last_rows(expected_struct_structs);

  CUDF_TEST_EXPECT_COLUMNS_EQUIVALENT(output, expected_sliced_structs);
}

}  // namespace cudf::test

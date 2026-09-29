function main() {
  return Events({
    from_date: "2026-05-01",
    to_date: "2026-06-27"
  })
    .groupBy(["name"], mixpanel.reducer.count())
    .filter(function(row) {
      var n = row.key[0];
      return n === "recipe_cart_add_footer_clicked" ||
             n === "recipe_ingredient_add_clicked" ||
             n === "cart_purchase_completed" ||
             n === "affiliate_link_clicked" ||
             n === "ingredient_purchased" ||
             n === "ingredient_purchase_checked";
    });
}

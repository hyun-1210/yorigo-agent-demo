function main() {
  var params = {
    from_date: "2026-05-01",
    to_date: "2026-06-27"
  };
  return Events(params)
    .filter(function(e) {
      return e.name === "recipe_cart_add_footer_clicked" ||
             e.name === "recipe_ingredient_add_clicked";
    })
    .groupByUser(mixpanel.reducer.count())
    .map(function(row) {
      return row.key;
    })
    .map(function(distinct_id) {
      return Events({
        from_date: params.from_date,
        to_date: params.to_date,
        selector: 'properties["$distinct_id"] == "' + distinct_id + '"'
      })
        .filter(function(e) {
          return e.name === "cart_purchase_completed" ||
                 e.name === "ingredient_purchased" ||
                 e.name === "affiliate_link_clicked";
        })
        .reduce(mixpanel.reducer.count());
    });
}

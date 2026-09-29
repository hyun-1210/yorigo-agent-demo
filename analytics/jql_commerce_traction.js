function main() {
  return Events({ from_date: params.from_date, to_date: params.to_date })
    .filter(function (e) {
      return (
        e.name === "sign_up" ||
        e.name === "affiliate_link_clicked" ||
        e.name === "cart_purchase_completed" ||
        e.name === "ingredient_purchase_checked" ||
        e.name === "cart_majority_checked" ||
        e.name === "recipe_cart_add_footer_clicked" ||
        e.name === "recipe_ingredient_add_clicked"
      );
    })
    .groupByUser(function (state, events) {
      state = state || {
        signup: 0,
        affiliate: 0,
        purchase: 0,
        checked: 0,
        majority: 0,
        cart_click: 0,
      };
      for (var i = 0; i < events.length; i++) {
        var n = events[i].name;
        if (n === "sign_up") state.signup = 1;
        if (n === "affiliate_link_clicked") state.affiliate = 1;
        if (n === "cart_purchase_completed") state.purchase = 1;
        if (n === "ingredient_purchase_checked") state.checked = 1;
        if (n === "cart_majority_checked") state.majority = 1;
        if (
          n === "recipe_cart_add_footer_clicked" ||
          n === "recipe_ingredient_add_clicked"
        ) {
          state.cart_click = 1;
        }
      }
      return state;
    });
}

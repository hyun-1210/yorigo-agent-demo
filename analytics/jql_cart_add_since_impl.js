function main() {
  return Events({ from_date: params.from_date, to_date: params.to_date })
    .filter(function (e) {
      return (
        e.name === "sign_up" ||
        e.name === "recipe_cart_add_footer_clicked" ||
        e.name === "recipe_ingredient_add_clicked"
      );
    })
    .groupByUser(function (state, events) {
      state = state || { signup: 0, cart: 0 };
      for (var i = 0; i < events.length; i++) {
        var n = events[i].name;
        if (n === "sign_up") {
          state.signup = 1;
        }
        if (
          n === "recipe_cart_add_footer_clicked" ||
          n === "recipe_ingredient_add_clicked"
        ) {
          state.cart = 1;
        }
      }
      return state;
    });
}
